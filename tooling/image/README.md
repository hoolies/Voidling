# Bootable VM image and ISO (prototype)

This directory builds **UEFI-bootable artifacts** from a composed product rootfs (`minimal` or `plasma`) that was composed with `BOOTABLE=1` (kernel + EFI GRUB):

- `build-vm-uefi-qcow2.sh` — GPT disk image (ESP + ext4 root) as qcow2
- `boot-qemu.sh` — QEMU + OVMF launcher for that qcow2 or the live ISO
- `build-iso.sh` — hybrid installer/live ISO (GRUB + live kargs + optional squashfs)
- `install-live-dracut.sh` — install dmsquash-live dracut config and rebuild the initrd

The qcow2 prototype uses **ext4** on a simple GPT + ESP + root layout. Product filesystem choice (ZFS or Btrfs) is an installer decision and is not applied here.

Two product images (not a third `bootable` variant):

| Item | Minimal | Plasma |
|------|---------|--------|
| Compose | `compose-bootable-rootfs.sh --variant=minimal` | `compose-bootable-rootfs.sh --variant=plasma` |
| Rootfs | `out/rootfs-x86_64-glibc-minimal/` | `out/rootfs-x86_64-glibc-plasma/` |
| OSTree ref | `voidling/x86_64/glibc/minimal` | `voidling/x86_64/glibc/plasma` |
| Default qcow2 | `out/voidling-x86_64-uefi-minimal.qcow2` (8G) | `out/voidling-x86_64-uefi-plasma.qcow2` (20G) |

## Host prerequisites

### Compose the bootable rootfs

- `xbps-install` (Void host or equivalent)
- Network access to official Void repos
- Enough disk for `out/rootfs-x86_64-glibc-minimal/` or `…-plasma/`

### qcow2 builder (requires **root**)

Root is required for loop devices, mounts, `mkfs`, and `grub-install`.

- `qemu-img` (QEMU)
- `parted`
- `losetup`, `mount`, `umount`, `blkid` (util-linux)
- `mkfs.vfat` (dosfstools)
- `mkfs.ext4` (e2fsprogs)
- `chroot`, `truncate`
- Optional: `partprobe`, `udevadm` (faster partition-node settle)

The builder creates a **sparse raw** disk, attaches it with `losetup --partscan`, then `qemu-img convert`s to qcow2. Loop-on-qcow2 is avoided because partition scan on qcow2 is unreliable. An NBD path (`qemu-nbd`) is not used.

### ISO builder

One writer path is enough:

- Preferred: `grub-mkrescue` + `xorriso` (hybrid BIOS + UEFI)
- Fallback: `grub-mkstandalone` + `xorriso` (EFI-only; needs `mtools` **or** root to mount a FAT EFI image)

Optional:

- `mksquashfs` (`squashfs-tools`) — packs `live/filesystem.squashfs` for live boot and the installer
- `mmd` / `mcopy` (`mtools`) — populate the EFI FAT image without root

Root is recommended when packing squashfs (device nodes, root-only files such as `/etc/shadow`).

### Live initrd (required for a writable live session)

`BOOTABLE=1` compose installs `dracut` and the OSTree module; that initrd is
wrong for squashfs live media. After compose:

```bash
sudo bash tooling/image/install-live-dracut.sh --variant=minimal
sudo bash tooling/image/install-live-dracut.sh --variant=plasma
```

That copies `tooling/image/live-dracut.conf` (same text as `overlays/live/etc/dracut.conf.d/50-voidling-live.conf`) into the rootfs and runs `dracut --force --no-hostonly --omit voidling-ostree`. Rebuild needs root (chroot mounts). Config-only: `--no-rebuild`.

`dmsquash-live` is skipped when `hostonly` is set. The live conf forces `hostonly=no` and adds iso9660/squashfs/overlay/CD/virtio drivers.

### QEMU run (`boot-qemu.sh`)

- `qemu-system-x86_64`
- OVMF / EDK2 firmware (package name varies)

`boot-qemu.sh` auto-detects non-secure-boot CODE firmware from:

- Void: `/usr/share/edk2-ovmf/x64/OVMF_CODE.fd`, `/usr/share/edk2/x64/OVMF_CODE.fd`, or `/usr/share/OVMF/OVMF_CODE.fd`
- Debian/Ubuntu: `/usr/share/OVMF/OVMF_CODE.fd` or `/usr/share/OVMF/OVMF_CODE_4M.fd`
- Fedora: `/usr/share/edk2/ovmf/OVMF_CODE.fd`
- QEMU bundle: `/usr/share/qemu/edk2-x86_64-code.fd` or `/usr/share/qemu/OVMF.fd`

Override with `--ovmf-code`, `--ovmf-vars`, or `--bios`. pflash is used when a matching `OVMF_VARS*.fd` sits next to CODE; otherwise `-bios`.

## Compose a bootable product rootfs

From the repo root (do **not** run this inside a capability-restricted sandbox):

```bash
bash tooling/compose/compose-bootable-rootfs.sh --variant=minimal
bash tooling/compose/compose-bootable-rootfs.sh --variant=plasma
```

`BOOTABLE=1` adds `linux` + `grub-x86_64-efi` + `dracut`. After overlays the tree is sealed (`/etc` → `/usr/etc`). The kernel is in `/boot` (Void `linux`) and/or `/usr/lib/modules/<kver>/vmlinuz`.

Equivalent:

```bash
BOOTABLE=1 bash tooling/compose/compose-minimal-rootfs.sh
BOOTABLE=1 bash tooling/compose/compose-plasma-rootfs.sh
```

Optional OSTree commit:

```bash
VARIANT=minimal bash tooling/ostree/commit-rootfs.sh
VARIANT=plasma bash tooling/ostree/commit-rootfs.sh
```

## Build qcow2 (UEFI)

From the repo root (requires **root**):

```bash
sudo bash tooling/image/build-vm-uefi-qcow2.sh --variant=minimal
sudo bash tooling/image/build-vm-uefi-qcow2.sh --variant=plasma
```

The builder looks for a kernel in `/boot` or `/usr/lib/modules` (skips OSTree placeholder kvers). A sealed tree (`/usr/etc`, no `/etc`) is restored to `/etc` on the image so the prototype VM can boot without OSTree deploy.

Useful options / environment:

```bash
sudo bash tooling/image/build-vm-uefi-qcow2.sh \
  --variant plasma \
  --rootfs out/rootfs-x86_64-glibc-plasma \
  --output out/voidling-x86_64-uefi-plasma.qcow2 \
  --size 20G
```

Output: `out/voidling-x86_64-uefi-minimal.qcow2` or `…-plasma.qcow2`

The image gets a UUID-based `/etc/fstab`, a regenerated initramfs with **ext4 + virtio** and **without** the compose `voidling-ostree` module (this disk is not an OSTree sysroot), `grub-install` (UEFI, `--removable` so `EFI/BOOT/BOOTX64.EFI` exists for OVMF), and a static `/boot/grub/grub.cfg` that points at the detected kernel path (`/boot/...` or `/usr/lib/modules/...`) plus `console=tty0 console=ttyS0`.

## Build ISO

Full live path (BOOTABLE rootfs → live initrd → ISO):

```bash
bash tooling/compose/compose-bootable-rootfs.sh --variant=minimal
sudo bash tooling/image/install-live-dracut.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal --squashfs
bash tooling/image/boot-qemu.sh --iso --variant=minimal
```

Plasma:

```bash
bash tooling/compose/compose-bootable-rootfs.sh --variant=plasma
sudo bash tooling/image/install-live-dracut.sh --variant=plasma
sudo bash tooling/image/build-iso.sh --variant=plasma
```

Root is not always required for a GRUB + kernel ISO. Use `sudo` when packing squashfs from a real composed rootfs, and when rebuilding the live initrd.

```bash
bash tooling/image/build-iso.sh --help
bash tooling/image/build-iso.sh --no-squashfs
bash tooling/image/build-iso.sh --squashfs   # fail if mksquashfs is missing
# reuse an already-packed squashfs (skip mksquashfs):
# bash tooling/image/build-iso.sh --variant=plasma --squashfs-file=/path/to/filesystem.squashfs
```

Output: `out/voidling-x86_64-uefi-minimal.iso` or `…-plasma.iso`

ISO layout:

- `/boot/vmlinuz`, `/boot/initrd` — copied from the bootable rootfs
- `/boot/grub/grub.cfg` — live, live-debug, and rescue entries
- `/live/filesystem.squashfs` — live root + installer payload (when `mksquashfs` is available)
- `/README.voidling.txt` — payload notes for other agents

Plasma squashfs is larger than 4 GiB. `build-iso.sh` writes ISO 9660 level 3 (multi-extent files) so xorriso can pack it. Minimal stays well under the old limit.

Live kernel arguments:

`rd.live.image rd.overlay rd.live.dir=live rd.live.squashimg=filesystem.squashfs root=live:CDLABEL=VOIDLING console=tty0 console=ttyS0 rw`

A sealed compose tree has `/usr/etc` and no `/etc`. `build-iso.sh` copies `/usr/etc` → `/etc` for the squashfs only, then removes that temporary `/etc` so the compose tree stays sealed.

The live squashfs also ships the installer (`voidling-installer`, `install-voidling`) plus `tooling/{installer,snapshots,ostree,boot,firstboot}` under `/usr/lib/voidling`. Those copies are removed from the compose tree after packing. Live defaults: `VARIANT` from the ISO variant, `FILESYSTEM=zfs`, staging under `/var/tmp/voidling`.

A full writable live session still needs a **BOOTABLE** rootfs (`linux` + `dracut`) whose initrd was rebuilt with dmsquash-live and **without** `voidling-ostree`. The ISO builder only packs what is already in the rootfs.

## Boot the qcow2 with QEMU + OVMF

From the repo root. Default image is `out/voidling-x86_64-uefi-$VARIANT.qcow2`.

```bash
bash tooling/image/boot-qemu.sh --variant=minimal
bash tooling/image/boot-qemu.sh --variant=plasma
```

Useful options:

```bash
bash tooling/image/boot-qemu.sh --help
bash tooling/image/boot-qemu.sh --variant=minimal --nographic
bash tooling/image/boot-qemu.sh \
  --variant=plasma \
  --image out/voidling-x86_64-uefi-plasma.qcow2 \
  --memory 4096 \
  --cpus 4
```

KVM is used when `/dev/kvm` is usable; otherwise TCG. Memory defaults: 2048 MiB (`minimal`), 4096 MiB (`plasma`).

Boot the ISO with the same helper:

```bash
bash tooling/image/boot-qemu.sh --iso --variant=minimal
bash tooling/image/boot-qemu.sh --iso --variant=minimal --nographic
bash tooling/image/boot-qemu.sh --iso --variant=plasma --nographic
```

`--iso` uses `out/voidling-x86_64-uefi-$VARIANT.iso`. Override with `--iso=FILE` or `--cdrom FILE`.

Manual QEMU (adjust OVMF for your distro):

```bash
qemu-system-x86_64 \
  -machine q35 \
  -m 4096 \
  -enable-kvm \
  -bios /usr/share/OVMF/OVMF_CODE.fd \
  -cdrom out/voidling-x86_64-uefi-minimal.iso \
  -boot d
```

## Integration

See `INTEGRATION.md` for hooks the installer, OSTree-deploy, and GRUB-rollback agents should consume. This prototype does not implement those features.
