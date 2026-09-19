#!/bin/bash
#
# Boot another PC into the Arch live ISO over an ethernet cable from this
# laptop, so no USB stick is needed.  This laptop becomes DHCP + TFTP + HTTP
# server on a bridge and shares its internet connection with the target, so
# install.sh works there exactly as it does from a stick.
#
#   sudo ./pxe.sh up ~/vm/archlinux-*.iso   # start serving (extracts the ISO once)
#   sudo ./pxe.sh down                      # stop and remove everything it set up
#   sudo ./pxe.sh vm                        # add a tap for a local qemu test, prints the qemu command
#   ./pxe.sh status
#
# On the target: pick "UEFI network boot" (PXE, IPv4) in the boot menu.  The
# firmware fetches iPXE over TFTP, iPXE fetches a boot script and then the
# kernel, initramfs and live image over HTTP, and the target lands in the same
# live environment the stick gives you, already online.  Then run install.sh.
#
# Needs: dnsmasq (pacman -S dnsmasq), libarchive, python, NetworkManager, and
# iPXE: the ipxe package if installed, otherwise downloaded from ipxe.org.

set -euo pipefail

BR=colinux-pxe
ADDR=10.42.0.1
STATE=/var/lib/colinux-pxe
DROPIN=/etc/NetworkManager/dnsmasq-shared.d/$BR.conf
TAP=colinux-tap

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }
need_root() { [[ $EUID -eq 0 ]] || die "run with sudo"; }

# range-capable static server (the archiso hook probes the image with a Range request)
HTTPD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pxe-httpd.py
HTTP_CMD="python $HTTPD 80 $ADDR $STATE/http"
http_pid() { pgrep -f -x "$HTTP_CMD" | head -1 || true; }
http_running() { [[ -n $(http_pid) ]]; }
stop_http() {
	pkill -f -x "$HTTP_CMD" 2> /dev/null || true
	pkill -f -x "python -m http.server 80 --bind $ADDR" 2> /dev/null || true   # older pxe.sh
}

wired_devices() {
	nmcli -t -f DEVICE,TYPE device | awk -F: '$2 == "ethernet" { print $1 }'
}

cmd_up() {
	need_root
	local iso=${1:-}
	[[ -n $iso && -f $iso ]] || die "usage: pxe.sh up <archlinux.iso>"
	command -v dnsmasq > /dev/null || die "dnsmasq missing: pacman -S dnsmasq"
	iso=$(realpath "$iso")

	mkdir -p "$STATE"
	chmod 755 "$STATE"

	# ---- live ISO contents, extracted once per ISO
	if [[ ! -f $STATE/iso.src || $(cat "$STATE/iso.src") != "$iso" ]]; then
		say "extracting $iso (takes a minute)"
		rm -rf "$STATE/iso"
		mkdir -p "$STATE/iso"
		bsdtar -xf "$iso" -C "$STATE/iso"
		chmod -R a+rX "$STATE/iso"
		echo "$iso" > "$STATE/iso.src"
	fi
	[[ -f $STATE/iso/arch/x86_64/airootfs.sfs ]] || die "$iso does not look like an Arch ISO"

	# ---- iPXE binary: the firmware's PXE loads it, it does the rest
	if [[ ! -f $STATE/ipxe.efi ]]; then
		if [[ -f /usr/share/ipxe/x86_64/ipxe.efi ]]; then
			cp /usr/share/ipxe/x86_64/ipxe.efi "$STATE/ipxe.efi"
		else
			say "downloading iPXE from boot.ipxe.org (or: pacman -S ipxe)"
			curl -fsSL -o "$STATE/ipxe.efi" https://boot.ipxe.org/x86_64-efi/ipxe.efi
		fi
		chmod 644 "$STATE/ipxe.efi"
	fi

	# ---- TFTP: just iPXE.  HTTP: iPXE's boot script + the ISO contents
	say "building TFTP and HTTP trees"
	rm -rf "$STATE/tftp" "$STATE/http"
	mkdir -p "$STATE/tftp" "$STATE/http"
	cp "$STATE/ipxe.efi" "$STATE/tftp/ipxe.efi"
	ln -s "$STATE/iso/arch" "$STATE/http/arch"
	# The initramfs' DHCP client (klibc ipconfig) never gets a lease on current
	# kernels, so iPXE hands the lease it already has to the kernel as a static
	# address.  net.ifnames=0 keeps the interface called eth0 for that.
	cat > "$STATE/http/boot.ipxe" <<-IPXE
	#!ipxe
	echo colinux: booting the Arch live system from http://$ADDR/ as \${net0/ip}
	kernel http://$ADDR/arch/boot/x86_64/vmlinuz-linux archisobasedir=arch archiso_http_srv=http://$ADDR/ ip=\${net0/ip}:$ADDR:\${net0/gateway}:\${net0/netmask}::eth0:none net.ifnames=0 cms_verify=y
	initrd http://$ADDR/arch/boot/x86_64/initramfs-linux.img
	boot
	IPXE
	chmod -R a+rX "$STATE/tftp" "$STATE/http"

	# ---- dnsmasq: NetworkManager's shared-mode instance reads this directory
	say "writing $DROPIN"
	mkdir -p "$(dirname "$DROPIN")"
	cat > "$DROPIN" <<-DNSMASQ
	# colinux PXE.  UEFI x86_64 firmware gets iPXE over TFTP; iPXE itself
	# (it sets DHCP option 175) gets the boot script over HTTP.
	enable-tftp
	tftp-root=$STATE/tftp
	dhcp-match=set:efi64,option:client-arch,7
	dhcp-match=set:efi64,option:client-arch,9
	dhcp-match=set:ipxe,175
	dhcp-boot=tag:ipxe,http://$ADDR/boot.ipxe
	dhcp-boot=tag:!ipxe,tag:efi64,ipxe.efi
	DNSMASQ

	# ---- bridge with shared IPv4 (DHCP + NAT to whatever this laptop is on),
	#      with every wired port attached so the cable can go in any of them
	say "bringing up bridge $BR at $ADDR"
	if ! nmcli -t -f NAME con show | grep -qx "$BR"; then
		nmcli con add type bridge con-name "$BR" ifname "$BR" \
			bridge.stp no ipv4.method shared ipv4.addresses "$ADDR/24" \
			ipv6.method disabled connection.autoconnect no > /dev/null
	fi
	local dev
	for dev in $(wired_devices); do
		if ! nmcli -t -f NAME con show | grep -qx "$BR-$dev"; then
			nmcli con add type ethernet con-name "$BR-$dev" ifname "$dev" \
				master "$BR" connection.autoconnect yes \
				connection.autoconnect-priority 100 > /dev/null
		fi
	done
	# (re)start so dnsmasq picks up the drop-in
	nmcli con down "$BR" > /dev/null 2>&1 || true
	nmcli con up "$BR" > /dev/null
	for dev in $(wired_devices); do
		nmcli con up "$BR-$dev" > /dev/null 2>&1 || true   # fails without carrier, joins later
	done

	# NM applies the address a moment after activation; wait for it
	local n=0
	until ip -4 addr show dev "$BR" | grep -q "inet $ADDR/"; do
		sleep 0.2
		n=$((n + 1))
		[[ $n -lt 50 ]] || die "$BR never got $ADDR (nmcli device show $BR)"
	done

	# ---- HTTP: boot script, kernel, initramfs and the live system image
	stop_http
	say "serving $STATE/http over http://$ADDR/"
	setsid -f $HTTP_CMD > "$STATE/http.log" 2>&1
	sleep 0.5
	http_running || die "http server failed to start, see $STATE/http.log"

	cat <<-DONE

	Ready.  Plug the cable into the target and boot it with UEFI network boot
	(PXE over IPv4).  It should land in the Arch live prompt, online, in a
	minute or two.  Then:

	    bash <(curl -fsSL https://raw.githubusercontent.com/salustiana/colinux/master/install.sh)

	Stop with:  sudo ./pxe.sh down
	DONE
}

cmd_down() {
	need_root
	stop_http
	local c
	for c in $(nmcli -t -f NAME con show | grep -E "^$BR(-|$)"); do
		say "removing connection $c"
		nmcli con delete "$c" > /dev/null
	done
	rm -f "$DROPIN"
	say "down (the extracted ISO stays in $STATE; rm -rf it to reclaim space)"
}

cmd_vm() {
	need_root
	nmcli -t -f NAME con show --active | grep -qx "$BR" || die "run 'pxe.sh up' first"
	local owner=${SUDO_UID:-0}
	if ! nmcli -t -f NAME con show | grep -qx "$BR-$TAP"; then
		say "adding tap $TAP to $BR for qemu (owner uid $owner)"
		nmcli con add type tun con-name "$BR-$TAP" ifname "$TAP" mode tap \
			owner "$owner" master "$BR" > /dev/null
	fi
	nmcli con up "$BR-$TAP" > /dev/null
	cat <<-VM

	Tap $TAP is on the bridge.  Arch's OVMF firmware has no network boot
	stack, so the VM starts iPXE directly as its kernel image; from there on
	the path is the same as on real hardware.  As your user:

	    qemu-img create -f qcow2 test.qcow2 30G
	    qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \\
	        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \\
	        -drive file=test.qcow2,if=virtio \\
	        -nic tap,ifname=$TAP,script=no,downscript=no,model=virtio-net-pci \\
	        -kernel $STATE/ipxe.efi -vga virtio

	Once installed, drop the -kernel line to boot the installed disk.
	VM
}

cmd_status() {
	echo "bridge:      $(nmcli -t -f NAME,DEVICE,STATE con show --active | grep "^$BR" || echo down)"
	echo "dnsmasq:     $(pgrep -a dnsmasq | grep -o "$BR\|dnsmasq-shared" | head -1 || echo not running)"
	if http_running; then echo "http:        pid $(http_pid), http://$ADDR/"; else echo "http:        not running"; fi
	echo "tftp/http:   $(ls "$STATE/tftp" 2> /dev/null | tr '\n' ' ')/ $(ls "$STATE/http" 2> /dev/null | tr '\n' ' ')"
	echo "iso:         $(cat "$STATE/iso.src" 2> /dev/null || echo none extracted)"
	echo "dhcp leases:"; cat /var/lib/NetworkManager/dnsmasq-"$BR".leases 2> /dev/null | sed 's/^/    /' || true
}

case ${1:-} in
	up)     shift; cmd_up "$@" ;;
	down)   cmd_down ;;
	vm)     cmd_vm ;;
	status) cmd_status ;;
	*)      sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 1 ;;
esac
