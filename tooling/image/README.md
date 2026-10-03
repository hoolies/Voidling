# Bootable VM image and ISO (prototype)

This directory builds **UEFI-bootable artifacts** from a composed product rootfs (`minimal` or `plasma`) that was composed with `BOOTABLE=1` (kernel + EFI GRUB):

- `build-vm-uefi-qcow2.sh` — GPT disk image (ESP + ext4 root) as qcow2
- `build-ostree-qcow2.sh` — GPT disk image with an OSTree deployment on Btrfs or ZFS
- `boot-qemu.sh` — QEMU + OVMF launcher for that qcow2 or the live ISO
- `build-iso.sh` — hybrid installer/live ISO (GRUB + live kargs + optional squashfs)
- `install-live-dracut.sh` — build `out/initramfs-$ARCH-$LIBC-$VARIANT-live.img` (does not modify the rootfs)

The **ext4** qcow2 (`build-vm-uefi-qcow2.sh`) uses a simple GPT + ESP + root layout without OSTree. **`build-ostree-qcow2.sh`** runs the real disk installer (Btrfs default, or ZFS with `--filesystem=zfs`); GRUB lands on the ESP via `install-bootloader.sh` when disk apply is armed.

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

That writes `out/initramfs-x86_64-glibc-$VARIANT-live.img`. Dracut sees `tooling/image/live-dracut.conf` (same text as `overlays/live/etc/dracut.conf.d/50-voidling-live.conf`) through a temporary `--confdir`. The composed tree's `/boot/initramfs-*.img` and `/usr/etc` stay as compose left them. Rebuild needs root (chroot mounts). `--no-rebuild` writes nothing.

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

The image gets a UUID-based `/etc/fstab`, a regenerated initramfs with **ext4 + virtio** and **without** the compose `voidling-ostree` module (this disk is not an OSTree sysroot), `grub-install` (UEFI, `--removable` so `EFI/BOOT/BOOTX64.EFI` exists for OVMF), and a static `/boot/grub/grub.cfg` that points at the detected kernel path (`/boot/...` or `/usr/lib/modules/...`) plus `zswap.enabled=0 console=tty0 console=ttyS0`.

## Build OSTree qcow2 (Btrfs or ZFS)

Requires a committed archive repo (`VARIANT=… bash tooling/ostree/commit-rootfs.sh`) and **root**:

```bash
sudo bash tooling/image/build-ostree-qcow2.sh --variant=minimal --filesystem=btrfs
sudo bash tooling/image/build-ostree-qcow2.sh --variant=minimal --filesystem=zfs
bash tooling/image/boot-qemu.sh --image out/voidling-x86_64-uefi-ostree-btrfs.qcow2
```

The installer partitions the loop disk, deploys OSTree, and `install-bootloader.sh` runs `grub-install` plus an ESP chain that loads **`/boot/grub.cfg`** (filesystem label `VOIDLING_ROOT` on Btrfs, pool name on ZFS).

## Build ISO

Full live path (BOOTABLE rootfs → live initrd → ISO):

```bash
bash tooling/compose/compose-bootable-rootfs.sh --variant=minimal
sudo bash tooling/image/install-live-dracut.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal --squashfs
bash tooling/image/boot-qemu.sh --iso --variant=minimal
```

Plasma and plasma-fenestration ISOs boot the **minimal** live rootfs and carry `ostree-repo/` on the disc. They do not pack the desktop tree as the squashfs. Pass `--rootfs` to pack a specific tree instead.

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

`rd.live.image rd.overlay rd.live.dir=live rd.live.squashimg=filesystem.squashfs root=live:CDLABEL=VOIDLING console=tty0 console=ttyS0 zswap.enabled=0 rw`

A sealed compose tree has `/usr/etc` and no `/etc`. `build-iso.sh` copies `/usr/etc` → `/etc` for the squashfs only, then removes that temporary `/etc` so the compose tree stays sealed.

The live squashfs also ships the installer (`voidling-installer`, `install-voidling`) plus `tooling/{installer,snapshots,ostree,boot,firstboot}` under `/usr/lib/voidling`. Those copies are removed from the compose tree after packing. Live defaults: `VARIANT` from the ISO variant, `FILESYSTEM=auto` (Btrfs on the shipped `WITH_ZFS=0` ISOs), staging under `/var/tmp/voidling`. Live root has no password; `voidling`/`voidling` is the lab user. `build-iso.sh --secure-boot` signs the chain (`tooling/boot/SECURE-BOOT.md`); `SQUASHFS_COMP=zstd` is available. `clean-out.sh` prunes OSTree history and stale `out/tmp`.

A full writable live session still needs a **BOOTABLE** rootfs (`linux` + `dracut`) and the side initrd from `install-live-dracut.sh` (dmsquash-live, without `voidling-ostree`). The ISO packs that file as `/boot/initrd`. It does not pack `/boot/initramfs-*.img` from the rootfs.

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

## Housekeeping

`clean-out.sh` is a dry run by default: it prints the `ostree prune` plan
for `out/ostree-repo*` (keeps current + previous commit per ref), lists
`out/tmp` entries older than 24h, and lists the qcow2/ISO artifacts. With
`--apply` (root for root-owned repos) it prunes and deletes the stale
scratch dirs. It never removes keys, rootfs trees, or images.

## Integration

See `INTEGRATION.md` for hooks the installer, OSTree-deploy, and GRUB-rollback agents should consume. This prototype does not implement those features.
