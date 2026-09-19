# colinux

My Arch setup (bspwm + sxhkd + polybar, alacritty, neovim) as one repo, plus
an installer that brings a fresh machine to it from the official Arch ISO.

## Fresh machine

1. Boot the stock Arch ISO from a USB stick (UEFI).
2. Get online: `iwctl station wlan0 connect <ssid>`, or plug in ethernet.
3. Run the installer:

       bash <(curl -fsSL https://raw.githubusercontent.com/salustiana/colinux/master/install.sh)

4. Answer the prompts: disk, hostname, LUKS passphrase, user password, and a
   final confirmation.  Then wait.
5. Remove the stick, reboot, log in, `startx`.  Run `:PlugInstall` once in nvim.

The result mirrors the current machine: GPT with a 2G EFI partition and a
LUKS2 root (ext4), systemd initramfs with `sd-encrypt`, GRUB, NetworkManager,
user `salus` in `wheel` and `video`, and the dotfiles below linked into the
home.  The wifi network used during the install is carried over to
NetworkManager so the new machine is online at first boot.  Root gets the same
password as the user.

Prompts can be preset through the environment (`DISK`, `NEW_HOSTNAME`,
`USERNAME`, `TIMEZONE`, `LOCALE`, `KEYMAP`, `LUKS_PASSPHRASE`, `USER_PASSWORD`);
see the top of `install.sh`.

## Fresh machine over an ethernet cable (no USB stick)

This laptop can serve the live ISO to a target PC over a direct cable.  Needs
`dnsmasq` installed here and the Arch ISO downloaded once.

    sudo pacman -S dnsmasq
    sudo ./pxe.sh up ~/vm/archlinux-*.iso

Plug the cable into the target and boot it with UEFI network boot (PXE, IPv4).
The target's firmware fetches iPXE from this laptop over TFTP; iPXE fetches a
boot script, the kernel and the initramfs over HTTP, and the live system pulls
its image the same way.  This laptop shares its internet connection over the
cable, so the target lands in the live prompt already online.  Then run the
installer one-liner as above.  `sudo ./pxe.sh down` removes the bridge, the
dnsmasq drop-in and the HTTP server; the extracted ISO stays in
`/var/lib/colinux-pxe`.

The target's firmware must support UEFI network boot; the installer refuses
BIOS-mode boots anyway.  iPXE comes from the `ipxe` package when installed,
otherwise `pxe.sh` downloads it from boot.ipxe.org once.

## Layout

    install.sh      the installer; run from the live ISO
    pxe.sh          serve the live ISO to another PC over ethernet (see PXE.md)
    pxe-httpd.py    range-capable static http server used by pxe.sh
    link.sh         symlink dotfiles/ into $HOME (rerunnable)
    packages.txt    explicitly installed packages, fed to pacstrap
    bin/pkglist     regenerate packages.txt from this machine
    dotfiles/       everything that lives in $HOME
    etc/            system files copied over /etc

## Day to day

Edit files in `dotfiles/` directly; the live ones in `$HOME` are symlinks to
them.  After installing or removing a package, run `./bin/pkglist` and commit.
On an existing machine, `./link.sh` is enough to adopt the dotfiles; it moves
any file it would overwrite to `<name>.orig`.

Not in the repo on purpose: anything with credentials or state (gh tokens,
ssh keys, wireguard and strongswan configs, browser profiles).

## Testing the installer in a VM

    sudo pacman -S qemu-desktop edk2-ovmf
    curl -LO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
    qemu-img create -f qcow2 test.qcow2 30G
    qemu-system-x86_64 -enable-kvm -m 4G -smp 4 \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
        -drive file=test.qcow2,if=virtio \
        -cdrom archlinux-x86_64.iso -boot d \
        -nic user,model=virtio-net-pci -vga virtio

Inside the VM the disk shows up as `vda`.  Drop `-cdrom` and `-boot d` to boot
the installed system afterwards.

To test the ethernet path, put a tap on the bridge and boot the VM from it.
Arch's OVMF build has no network boot stack, so the VM starts iPXE directly
via `-kernel`; everything after that is identical to real hardware.

    sudo ./pxe.sh up ~/vm/archlinux-*.iso
    sudo ./pxe.sh vm          # prints the qemu command to run as your user

To test uncommitted changes without pushing, serve the repo from the host
(`git update-server-info && python -m http.server 8000`) and in the VM run

    RAW_BASE=http://10.0.2.2:8000 REPO_URL=http://10.0.2.2:8000/.git \
        bash <(curl -fsSL http://10.0.2.2:8000/install.sh)
