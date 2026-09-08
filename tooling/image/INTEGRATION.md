# Image prototype — integration notes

This file is for **other agents** (installer, OSTree deploy, GRUB rollback, filesystem/snapshot). The image builders produce a UEFI qcow2 and a hybrid ISO from a **product** rootfs composed with `BOOTABLE=1` (`minimal` or `plasma`). They do **not** implement product install, OSTree deployment layout, or rollback UX.

## What this agent owns

- `tooling/image/*`
- `tooling/compose/compose-bootable-rootfs.sh` (wrapper: `BOOTABLE=1` + `--variant=minimal|plasma`)

## Variant wiring (already implemented)

`tooling/compose/compose-rootfs.sh` already names output as:

`out/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT/`

No patch to `compose-rootfs.sh` is requested. Product trees:

- `out/rootfs-x86_64-glibc-minimal/`
- `out/rootfs-x86_64-glibc-plasma/`

Optional commit:

```bash
VARIANT=minimal bash tooling/ostree/commit-rootfs.sh
VARIANT=plasma bash tooling/ostree/commit-rootfs.sh
```

## qcow2 on-disk layout (prototype only)

GPT, two partitions:

| Part | Role | Filesystem | Label | Mount |
|------|------|------------|-------|--------|
| 1 | ESP | FAT32 | `VOIDLINGEFI` | `/boot/efi` |
| 2 | root | ext4 | `VOIDLING_ROOT` | `/` |

- Starts at 1 MiB; ESP default size is 512 MiB (`EFI_SIZE_MIB`).
- `/etc/fstab` is UUID-based (`defaults` on ext4, `umask=0077` on the ESP).
- This is **not** the product disk layout. The installer chooses **ZFS or Btrfs** at install time. Do not assume ext4-in-qcow2 is the shipping root.

## GRUB (prototype)

`build-vm-uefi-qcow2.sh` runs `grub-install` with:

- `--target=x86_64-efi`
- `--efi-directory=/boot/efi`
- `--bootloader-id=Voidling`
- `--removable` (writes `EFI/BOOT/BOOTX64.EFI` for OVMF / removable media)
- `--no-nvram` (build host is not the target firmware)

Kernel detection (after the `/usr/etc` seal, the kernel is **not** only under `/boot`):

1. `$ROOTFS/boot/vmlinuz` or `$ROOTFS/boot/vmlinuz-*` (Void `linux` package)
2. `$ROOTFS/usr/lib/modules/<kver>/vmlinuz` (OSTree-style / Fedora path)
3. Skip kvers whose name contains `placeholder` (deploy-sysroot dummy is not bootable)
4. Initramfs: `/boot/initrd*`, `/boot/initramfs-*.img`, or `/usr/lib/modules/<kver>/initramfs.img`

A sealed compose tree has `/usr/etc` and no `/etc`. The qcow2 prototype is a regular disk (not an OSTree deploy), so the builder copies `/usr/etc` → `/etc` on the image before writing fstab and running `grub-install`.

The compose initramfs (`voidling-ostree` / BOOTABLE dracut) may omit `ext4` and assumes an OSTree sysroot. This prototype root is a plain ext4 disk, so the builder regenerates `/boot/initramfs-<kver>.img` with `--omit voidling-ostree --add-drivers "ext4 virtio_blk virtio_pci" --fstab` before `grub-install`. Product OSTree boot remains the deploy/boot agents' job.

It then writes a **single** static menu entry in `/boot/grub/grub.cfg`:

- `search --fs-uuid` for the ext4 root UUID
- `linux /<kernel-path> root=UUID=<root> rw console=tty0 console=ttyS0`
  (`/<kernel-path>` is `/boot/<vmlinuz>` or `/usr/lib/modules/<kver>/vmlinuz`)
- `initrd /<initrd-path>` when an initramfs was detected

### Hooks for the GRUB / rollback agent

- Do not treat this `grub.cfg` as the product boot menu.
- Product rollback UX (boot-menu entries + CLI) should replace or generate this file at **deploy** time (OSTree bootloader integration), not at qcow2-build time.
- `bootloader-id=Voidling` is the prototype NVRAM/EFI directory name; keep it or document a rename before shipping.
- The removable fallback path `EFI/BOOT/BOOTX64.EFI` is what QEMU+OVMF typically boots. A real installer should also register a non-fallback entry via `efibootmgr` on the target.

## QEMU helper

`tooling/image/boot-qemu.sh` boots the prototype qcow2 **or** the live ISO:

```bash
bash tooling/image/boot-qemu.sh --variant=minimal
bash tooling/image/boot-qemu.sh --iso --variant=minimal
```

- Default disk: `out/voidling-x86_64-uefi-$VARIANT.qcow2` (`--image` / `IMAGE_PATH` override).
- Default ISO: `out/voidling-x86_64-uefi-$VARIANT.iso` (`--iso`, `--iso=FILE`, `--cdrom FILE`).
- OVMF autodetection: Void (`/usr/share/edk2-ovmf/x64/OVMF_CODE.fd`, `/usr/share/edk2/x64/OVMF_CODE.fd`, `/usr/share/OVMF/OVMF_CODE.fd`), Debian/Ubuntu (`/usr/share/OVMF/OVMF_CODE.fd`, `OVMF_CODE_4M.fd`), Fedora (`/usr/share/edk2/ovmf/OVMF_CODE.fd`).
- pflash when a vars template is found (VARS is copied to a temp file and removed on EXIT). Combined `OVMF.fd` uses `-bios`.
- KVM when `/dev/kvm` is usable; `--no-kvm` forces TCG. `--nographic` is serial-on-stdio (matches `console=ttyS0` in the prototype grub.cfg).
- QEMU opens the qcow2 read-write. `build-vm-uefi-qcow2.sh` `chown`s the image to `SUDO_UID`/`SUDO_GID` when invoked via `sudo`, so `boot-qemu.sh` can run unprivileged.

## ISO payload (prototype)

`build-iso.sh` produces a hybrid ISO intended as an **installer/live** carrier:

| Path | Purpose |
|------|---------|
| `/boot/vmlinuz` | Kernel copied from the bootable rootfs |
| `/boot/initrd` | Initramfs (when present) |
| `/boot/grub/grub.cfg` | Live + debug + rescue; live kargs include `rd.live.dir=live` and `rd.live.squashimg=filesystem.squashfs` |
| `/live/filesystem.squashfs` | Squashfs of the rootfs (when `mksquashfs` is available). Plasma exceeds 4 GiB; the ISO is ISO 9660 level 3. |
| `/README.voidling.txt` | Same notes, shipped inside the ISO |
| Volume label | `VOIDLING` (override with `--label` / `ISO_LABEL`) |

Live kargs: `rd.live.image rd.overlay rd.live.dir=live rd.live.squashimg=filesystem.squashfs root=live:CDLABEL=VOIDLING console=tty0 console=ttyS0 rw`

A sealed compose tree has `/usr/etc` and no `/etc`. `build-iso.sh` restores `/etc` from `/usr/etc` into the squashfs only, then deletes that temporary `/etc`.

### Hooks for the installer agent

- Prefer `/live/filesystem.squashfs` as the payload to unpack or loop-mount.
- Live session: `sudo voidling-installer` (menu) or `sudo install-voidling` (flags), shipped inside the squashfs at `/usr/lib/voidling`.
- If squashfs is absent (`--no-squashfs` or missing `mksquashfs`), fall back to the composed directory `out/rootfs-x86_64-glibc-minimal/` or `…-plasma/` on the build/install host.
- Live boot needs an initrd that contains **dmsquash-live** and **omits** `voidling-ostree`. After compose, run `tooling/image/install-live-dracut.sh`. Do not bake live modules into the default OSTree/qcow2 initrd.
- The installer owns partitioning, ESP creation, and **ZFS vs Btrfs**. Do not reuse the qcow2 ext4 recipe on real hardware.

## OSTree deploy agent

- Commit ref to consume: `voidling/x86_64/glibc/minimal` or `voidling/x86_64/glibc/plasma` (after `BOOTABLE=1` compose + commit).
- The qcow2/ISO builders copy a **plain directory tree**. They do not create `/ostree/deploy`, bootc-style stateroots, or `ostree admin deploy`.
- First-boot or installer should deploy from the repo (`out/ostree-repo/` by default) and then write the real fstab + GRUB for that deployment.
- `/etc` and `/var` mutability policy belongs to the OSTree-deploy agent, not these image scripts.

## Compose-rootfs hook (BOOTABLE + live)

`compose-rootfs.sh` already honors `VARIANT` for the output directory. This tree does not patch that script.

**Do not** fold live modules into default `BOOTABLE=1` compose. OSTree boots need `voidling-ostree`; the qcow2 prototype omits it and adds ext4/virtio; the live ISO omits it and adds dmsquash-live. Keep those three initrds separate.

Live ISO path:

```bash
bash tooling/compose/compose-bootable-rootfs.sh --variant=minimal
sudo bash tooling/image/install-live-dracut.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal --squashfs
bash tooling/image/boot-qemu.sh --iso --variant=minimal
```

1. `install-live-dracut.sh` copies `overlays/live/etc/dracut.conf.d/50-voidling-live.conf` (or `tooling/image/live-dracut.conf`) into `/usr/etc` (and `/etc` if present) and rebuilds with `hostonly=no`, `--omit voidling-ostree`.
2. Module list (keep it in those two files, not here): `dmsquash-live overlayfs pollcdrom`, `omit voidling-ostree`, plus iso9660/squashfs/overlay/CD/virtio drivers.
3. Rebuild: `dracut --force --no-hostonly --omit voidling-ostree /boot/initramfs-<kver>.img <kver>`.

`dmsquash-live` refuses to install when `hostonly` is set. `device-mapper` (`dmsetup`) is pulled by `dracut` → `kpartx` on Void; do not drop that chain from a custom `PKGS` list.

## Out of scope (do not assume these exist)

- Installer TUI/CLI
- On-disk OSTree deployment layout
- Rollback boot-menu generation
- ZFS/Btrfs + snapshot automation
- Fenestration / Sourcing / Plasma-in-VM defaults
