#!/bin/bash
#
# Arch install from the official live ISO, hands-off after a few prompts:
#
#   iwctl station wlan0 connect <ssid>        # or plug in ethernet
#   bash <(curl -fsSL https://raw.githubusercontent.com/salustiana/colinux/master/install.sh)
#
# What you get: GPT, 2G EFI + LUKS2 root (ext4), systemd initramfs with
# sd-encrypt, GRUB, NetworkManager (with the wifi you used during the
# install already saved), one wheel user with the dotfiles from this repo
# linked into its home.
#
# Prompts: target disk, hostname, LUKS passphrase, user password, a final
# confirmation.  Each can be preset through the environment instead:
#   DISK=/dev/sda NEW_HOSTNAME=foo bash install.sh

set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/salustiana/colinux.git}
REPO_SSH=${REPO_SSH:-git@github.com:salustiana/colinux.git}
USERNAME=${USERNAME:-salus}
NEW_HOSTNAME=${NEW_HOSTNAME:-}
DISK=${DISK:-}
TIMEZONE=${TIMEZONE:-America/Argentina/Buenos_Aires}
LOCALE=${LOCALE:-C.UTF-8}
KEYMAP=${KEYMAP:-us}
EFI_SIZE=${EFI_SIZE:-2G}
# where the repo lives in the new user's home
REPO_DIR=${REPO_DIR:-on/colinux}
# packages the machine needs beyond packages.txt
EXTRA_PKGS="cryptsetup dosfstools"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
# read from the terminal even when the script itself arrives on stdin
ask() { read -r "$@" < /dev/tty; }

# ---------------------------------------------------------------- chroot leg
# The script re-runs itself inside the new system for the configuration that
# has to happen there.  Everything it needs comes through the environment.
if [[ ${1:-} == --chroot ]]; then
	: "${LUKS_UUID:?}" "${USERNAME:?}" "${NEW_HOSTNAME:?}" "${USER_PASSWORD:?}"
	repo=/home/$USERNAME/$REPO_DIR

	say "time and locale"
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
	hwclock --systohc
	if [[ $LOCALE != C.UTF-8 ]]; then
		sed -i "s/^#\($LOCALE\)/\1/" /etc/locale.gen
		locale-gen
	fi
	echo "LANG=$LOCALE" > /etc/locale.conf
	echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

	say "hostname"
	echo "$NEW_HOSTNAME" > /etc/hostname
	cat > /etc/hosts <<-HOSTS
	127.0.0.1        localhost
	::1              localhost
	127.0.1.1        $NEW_HOSTNAME
	HOSTS

	say "initramfs (systemd + sd-encrypt)"
	sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' \
		/etc/mkinitcpio.conf
	mkinitcpio -P

	say "grub"
	sed -i \
		-e "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.luks.name=$LUKS_UUID=root root=/dev/mapper/root\"|" \
		-e 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=2|' \
		-e 's|^#\?GRUB_DISABLE_RECOVERY=.*|GRUB_DISABLE_RECOVERY=true|' \
		/etc/default/grub
	grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
	# fallback path for firmware that ignores NVRAM entries
	grub-install --target=x86_64-efi --efi-directory=/boot --removable
	grub-mkconfig -o /boot/grub/grub.cfg

	say "user $USERNAME"
	groups=wheel,video
	getent group nix-users > /dev/null && groups+=,nix-users
	id "$USERNAME" &> /dev/null || useradd -m -G "$groups" -s /bin/bash "$USERNAME"
	printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chpasswd
	printf 'root:%s\n' "$USER_PASSWORD" | chpasswd
	echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
	chmod 440 /etc/sudoers.d/wheel

	say "system files from the repo"
	cp -r "$repo/etc/." /etc/

	say "services"
	systemctl enable NetworkManager
	systemctl enable nix-daemon 2> /dev/null || true
	if [[ -d /var/lib/postgres && ! -s /var/lib/postgres/data/PG_VERSION ]]; then
		sudo -u postgres initdb --locale=C.UTF-8 -E UTF8 -D /var/lib/postgres/data > /dev/null
		systemctl enable postgresql
	fi

	say "dotfiles"
	chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
	sudo -u "$USERNAME" env HOME="/home/$USERNAME" "$repo/link.sh"
	sudo -u "$USERNAME" git -C "$repo" remote set-url origin "$REPO_SSH"
	exit 0
fi

# ------------------------------------------------------------ live ISO leg
[[ $EUID -eq 0 ]] || die "run as root (on the live ISO you already are)"
[[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode"
command -v pacstrap > /dev/null || die "pacstrap missing: this is meant to run from the Arch live ISO"
curl -fsSI https://archlinux.org > /dev/null || die "no network; connect with iwctl first"

# Use the checkout we are running from when there is one, otherwise clone.
src=""
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
	here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	[[ -f $here/packages.txt && -f $here/link.sh ]] && src=$here
fi
if [[ -z $src ]]; then
	src=$(mktemp -d)
	say "fetching $REPO_URL"
	git clone -q "$REPO_URL" "$src"
fi

if [[ -z $DISK ]]; then
	say "disks"
	lsblk -d -o NAME,SIZE,MODEL,TRAN -e 7,11
	echo
	ask -p "install to which disk? (e.g. nvme0n1 or sda): " DISK
	DISK=/dev/${DISK#/dev/}
fi
[[ -b $DISK ]] || die "$DISK is not a block device"

if [[ -z $NEW_HOSTNAME ]]; then
	ask -p "hostname: " NEW_HOSTNAME
fi
[[ $NEW_HOSTNAME =~ ^[a-z0-9-]+$ ]] || die "hostname must be lowercase letters, digits, dashes"

ask_secret() {
	local prompt=$1 a b
	while true; do
		ask -sp "$prompt: " a; echo >&2
		ask -sp "$prompt (again): " b; echo >&2
		[[ -n $a && $a == "$b" ]] && { printf '%s' "$a"; return; }
		echo "empty or mismatch, try again" >&2
	done
}
LUKS_PASSPHRASE=${LUKS_PASSPHRASE:-$(ask_secret "LUKS passphrase")}
USER_PASSWORD=${USER_PASSWORD:-$(ask_secret "password for $USERNAME (and root)")}

case $DISK in
	*nvme*|*mmcblk*) part() { echo "${DISK}p$1"; } ;;
	*)               part() { echo "${DISK}$1"; } ;;
esac
EFI_PART=$(part 1)
LUKS_PART=$(part 2)

ucode=""
grep -q GenuineIntel /proc/cpuinfo && ucode=intel-ucode
grep -q AuthenticAMD /proc/cpuinfo && ucode=amd-ucode

mapfile -t PKGS < <(grep -v '^\s*#' "$src/packages.txt" | grep .)
# shellcheck disable=SC2206
PKGS+=($EXTRA_PKGS $ucode)

cat <<-SUMMARY

	================ about to install ================
	disk        $DISK   (ALL DATA ON IT WILL BE DESTROYED)
	layout      $EFI_PART  $EFI_SIZE EFI  |  $LUKS_PART  LUKS2 -> ext4 /
	hostname    $NEW_HOSTNAME
	user        $USERNAME  (wheel, video)
	timezone    $TIMEZONE
	locale      $LOCALE   keymap $KEYMAP
	microcode   ${ucode:-none}
	packages    ${#PKGS[@]}
	repo        $REPO_URL -> ~/$REPO_DIR
	==================================================
SUMMARY
ask -p "type the disk name ($(basename "$DISK")) to continue: " confirm
[[ $confirm == "$(basename "$DISK")" ]] || die "aborted"

timedatectl set-ntp true
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf

say "partitioning $DISK"
# make sure nothing from a previous attempt is still open
umount -R /mnt 2> /dev/null || true
cryptsetup close root 2> /dev/null || true
wipefs -af "$DISK" > /dev/null
sgdisk --zap-all "$DISK" > /dev/null
sgdisk -n 1:0:+$EFI_SIZE -t 1:ef00 -c 1:EFI \
       -n 2:0:0         -t 2:8309 -c 2:root "$DISK" > /dev/null
partprobe "$DISK"
udevadm settle
[[ -b $EFI_PART && -b $LUKS_PART ]] || die "partitions did not appear"

say "encrypting $LUKS_PART"
printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 --batch-mode "$LUKS_PART" -
printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open "$LUKS_PART" root -
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")

say "filesystems"
mkfs.fat -F32 -n EFI "$EFI_PART" > /dev/null
mkfs.ext4 -q -L root /dev/mapper/root
mount /dev/mapper/root /mnt
mount --mkdir "$EFI_PART" /mnt/boot

say "pacstrap (${#PKGS[@]} packages)"
pacstrap -K /mnt "${PKGS[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

say "copying repo into the new home"
dest=/mnt/home/$USERNAME/$REPO_DIR
mkdir -p "$(dirname "$dest")"
if [[ -d $src/.git ]]; then
	git clone -q "$src" "$dest"
else
	cp -r "$src" "$dest"
fi

# Hand the wifi networks iwd knows on the live system over to NetworkManager,
# so the new install is online at first boot.  iwd hex-encodes SSIDs with
# unusual characters (=HEX.psk); those are skipped.
shopt -s nullglob
for psk in /var/lib/iwd/*.psk; do
	ssid=${psk##*/}; ssid=${ssid%.psk}
	[[ $ssid == =* ]] && continue
	pass=$(sed -n 's/^Passphrase=//p' "$psk")
	[[ -n $pass ]] || continue
	say "saving wifi network $ssid for NetworkManager"
	conn=/mnt/etc/NetworkManager/system-connections/$ssid.nmconnection
	mkdir -p "$(dirname "$conn")"
	cat > "$conn" <<-NM
	[connection]
	id=$ssid
	type=wifi

	[wifi]
	ssid=$ssid
	mode=infrastructure

	[wifi-security]
	key-mgmt=wpa-psk
	psk=$pass

	[ipv4]
	method=auto

	[ipv6]
	method=auto
	NM
	chmod 600 "$conn"
done
shopt -u nullglob

say "configuring inside chroot"
arch-chroot /mnt env \
	LUKS_UUID="$LUKS_UUID" USERNAME="$USERNAME" NEW_HOSTNAME="$NEW_HOSTNAME" \
	USER_PASSWORD="$USER_PASSWORD" TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" \
	KEYMAP="$KEYMAP" REPO_DIR="$REPO_DIR" REPO_SSH="$REPO_SSH" \
	bash "/home/$USERNAME/$REPO_DIR/install.sh" --chroot

say "done"
umount -R /mnt
cryptsetup close root
cat <<-DONE

	Installed.  Remove the USB stick and reboot.
	Log in as $USERNAME and run startx.  In nvim run :PlugInstall once.
	If no wifi was carried over, connect with nmtui.
DONE
