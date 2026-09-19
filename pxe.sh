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
# On the target: pick "UEFI network boot" (PXE, IPv4) in the boot menu.  It
# gets the kernel and initramfs from here, pulls the live system image over
# HTTP, and lands in the same live environment the stick gives you, already
# online.  Then run install.sh as usual.
#
# Needs: dnsmasq (pacman -S dnsmasq), grub, libarchive, python, NetworkManager.

set -euo pipefail

BR=colinux-pxe
ADDR=10.42.0.1
STATE=/var/lib/colinux-pxe
DROPIN=/etc/NetworkManager/dnsmasq-shared.d/$BR.conf
TAP=colinux-tap

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }
need_root() { [[ $EUID -eq 0 ]] || die "run with sudo"; }

http_pid() { [[ -f $STATE/http.pid ]] && cat "$STATE/http.pid" || true; }
http_running() { local p; p=$(http_pid); [[ -n $p ]] && kill -0 "$p" 2> /dev/null; }

stop_http() {
	if http_running; then kill "$(http_pid)"; fi
	rm -f "$STATE/http.pid"
}

wired_devices() {
	nmcli -t -f DEVICE,TYPE device | awk -F: '$2 == "ethernet" { print $1 }'
}

cmd_up() {
	need_root
	local iso=${1:-}
	[[ -n $iso && -f $iso ]] || die "usage: pxe.sh up <archlinux.iso>"
	command -v dnsmasq > /dev/null || die "dnsmasq missing: pacman -S dnsmasq"
	command -v grub-mknetdir > /dev/null || die "grub missing"
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

	# ---- TFTP tree: GRUB netboot image + our menu; kernel and initramfs come
	#      from the extracted ISO through a symlink
	say "building TFTP tree"
	rm -rf "$STATE/tftp"
	grub-mknetdir --net-directory="$STATE/tftp" --subdir=/boot/grub > /dev/null
	ln -sfn "$STATE/iso/arch" "$STATE/tftp/arch"
	local opts="archisobasedir=arch archiso_http_srv=http://$ADDR/ ip=dhcp cms_verify=y"
	cat > "$STATE/tftp/boot/grub/grub.cfg" <<-GRUB
	set timeout=3
	set default=0

	# kernel + initramfs over HTTP (fast); the second entry is the fallback
	menuentry "Arch Linux live (colinux PXE, HTTP)" {
		insmod http
		linux (http,$ADDR)/arch/boot/x86_64/vmlinuz-linux $opts
		initrd (http,$ADDR)/arch/boot/x86_64/initramfs-linux.img
	}
	menuentry "Arch Linux live (colinux PXE, TFTP)" {
		linux /arch/boot/x86_64/vmlinuz-linux $opts
		initrd /arch/boot/x86_64/initramfs-linux.img
	}
	GRUB
	chmod -R a+rX "$STATE/tftp"

	# ---- dnsmasq: NetworkManager's shared-mode instance reads this directory
	say "writing $DROPIN"
	mkdir -p "$(dirname "$DROPIN")"
	cat > "$DROPIN" <<-DNSMASQ
	# colinux PXE: hand UEFI x86_64 clients the GRUB netboot image
	enable-tftp
	tftp-root=$STATE/tftp
	dhcp-match=set:efi64,option:client-arch,7
	dhcp-match=set:efi64,option:client-arch,9
	dhcp-boot=tag:efi64,boot/grub/x86_64-efi/core.efi
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

	# ---- HTTP: the live system image (and kernel/initramfs for GRUB)
	stop_http
	say "serving $STATE/iso over http://$ADDR/"
	(cd "$STATE/iso" && setsid python -m http.server 80 --bind "$ADDR" \
		> "$STATE/http.log" 2>&1 & echo $! > "$STATE/http.pid")
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

	Tap $TAP is on the bridge.  As your user, boot a VM from it (an empty disk
	makes the firmware fall through to network boot):

	    qemu-img create -f qcow2 test.qcow2 30G
	    qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \\
	        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \\
	        -drive file=test.qcow2,if=virtio \\
	        -nic tap,ifname=$TAP,script=no,downscript=no,model=virtio-net-pci \\
	        -vga virtio -boot menu=on

	If the firmware boots something else, press Esc at the logo and pick
	"UEFI PXEv4".  Once installed, the same command boots the installed disk.
	VM
}

cmd_status() {
	echo "bridge:      $(nmcli -t -f NAME,DEVICE,STATE con show --active | grep "^$BR" || echo down)"
	echo "dnsmasq:     $(pgrep -a dnsmasq | grep -o "$BR\|dnsmasq-shared" | head -1 || echo not running)"
	if http_running; then echo "http:        pid $(http_pid), http://$ADDR/"; else echo "http:        not running"; fi
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
