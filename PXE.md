# Installing over an ethernet cable

`pxe.sh` turns this laptop into a boot server so a target PC boots the Arch
live system straight from the cable, with no USB stick.  Once the target is at
the live prompt, `install.sh` runs exactly as it would from a stick.

## Setup, once

    sudo pacman -S dnsmasq
    sudo ./pxe.sh up ~/vm/archlinux-*.iso

`up` does five things:

1. **Extracts the ISO** to `/var/lib/colinux-pxe/iso` (only when the ISO changes).
2. **Gets iPXE**, a network bootloader: from the `ipxe` package if installed,
   otherwise downloaded once from boot.ipxe.org.
3. **Writes two trees.**  TFTP holds only `ipxe.efi`.  HTTP holds `boot.ipxe`,
   a four-line script, plus a symlink to the ISO's `arch/` directory.
4. **Writes a dnsmasq drop-in** in `/etc/NetworkManager/dnsmasq-shared.d/`:
   TFTP on, and two DHCP boot rules keyed on what the client says it is.
5. **Brings up a bridge** `colinux-pxe` at 10.42.0.1 in NetworkManager's
   *shared* mode, which runs dnsmasq for DHCP and NATs the target through
   this laptop's wifi.  Every wired port is attached to the bridge, so the
   cable can go into any of them.  A range-capable HTTP server
   (`pxe-httpd.py`) serves the HTTP tree on port 80.

## Boot, per target

Plug the cable in, boot the target, choose UEFI network boot (IPv4).

1. **Firmware asks DHCP.**  dnsmasq sees a UEFI x86_64 client
   (client-arch 7 or 9) and answers: your address is 10.42.0.x, boot file is
   `ipxe.efi`.  The firmware fetches it over TFTP and runs it.
2. **iPXE asks DHCP again.**  It marks its request with option 175, so
   dnsmasq now answers with `http://10.42.0.1/boot.ipxe` instead.
3. **iPXE runs the script**, which fetches the kernel and the 245 MB
   initramfs over HTTP and boots them with these parameters:
   - `archiso_http_srv=http://10.42.0.1/` tells the live initramfs where the
     root image lives.
   - `ip=<iPXE's lease>::eth0:none` hands the address iPXE already has to
     the kernel as a static one, because the initramfs' own DHCP client
     sends nothing on current kernels.
   - `net.ifnames=0` keeps the interface named `eth0` so that works.
   - `cms_verify=y` checks the image's signature, as the official ISO does.
4. **The initramfs downloads the 1 GB root image** into RAM over HTTP,
   verifies it, mounts it and switches to the live system.
5. **The live system starts**, does a normal DHCP (same address, same lease)
   and is online through the laptop.  Run the installer one-liner.

Elapsed on a gigabit cable: about a minute to the prompt.

## Afterwards

    sudo ./pxe.sh down      # removes bridge, drop-in, http server; keeps the extracted ISO
    ./pxe.sh status         # bridge, http server, dhcp leases

## Testing in a VM

Arch's OVMF firmware has no network boot stack, so the VM starts iPXE
directly as its kernel image and joins the bridge through a tap.  From step 2
on, the path is identical to real hardware.

    sudo ./pxe.sh vm        # adds the tap and prints the qemu command

## Limits

- The target must support UEFI network boot; BIOS-only machines need the stick.
- The live interface is assumed to be `eth0`.  On a machine with two wired
  ports the cable must be in the first, or the initramfs stops at a shell.
- iPXE, not the firmware, drives the NIC, so a very unusual NIC could lack an
  iPXE driver.  Serving `snponly.efi` instead of `ipxe.efi` uses the
  firmware's driver and is the fallback.
