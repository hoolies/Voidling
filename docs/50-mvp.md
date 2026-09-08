# Minimum Viable Product (MVP)

This MVP is the smallest artifact set that proves Voidling’s core promise:

- consume **unchanged** Void Linux `.xbps` binaries
- compose a filesystem tree
- commit it as an **OSTree-style** versioned root

## What exists today

| Variant | Compose preset | Rootfs | OSTree ref |
|---------|----------------|--------|------------|
| `minimal` | `tooling/compose/compose-minimal-rootfs.sh` | `out/rootfs-x86_64-glibc-minimal/` | `voidling/x86_64/glibc/minimal` |
| `plasma` | `tooling/compose/compose-plasma-rootfs.sh` | `out/rootfs-x86_64-glibc-plasma/` | `voidling/x86_64/glibc/plasma` |
| `plasma-fenestration` | `tooling/compose/compose-fenestration-rootfs.sh` | `out/rootfs-x86_64-glibc-plasma-fenestration/` | `voidling/x86_64/glibc/plasma-fenestration` |

**Minimal:** no DE/WM. Container seed vs `BOOTABLE=1` (kernel, GRUB, dracut, ostree, e2fsprogs, iproute2). Dash `/bin/sh`.

**Plasma:** full KDE + Bourne_Again skel + Tokyo Night Moon Plasma look + Flathub + Alacritty/Zen/Dolphin. `BOOTABLE=1` adds kernel, GRUB, dracut, ostree, e2fsprogs, iproute2, **zfs** (DKMS).

**Fenestration:** no Steam. Void packages (Wine, Lutris, Gamescope, …) verified present. Bottles/Heroic are Flatpak.

**Seal:** `/usr/etc`, `voidling-immutable` mounts, ostree dracut module on `BOOTABLE=1`.

## Proven on this host

- Minimal UEFI qcow2 composed, built, and booted in QEMU (GRUB → kernel → ext4 → runit).
- Minimal live ISO composed, packed, and booted in QEMU (GRUB → dmsquash-live → overlayfs → runit login on ttyS0). Artifact: `out/voidling-x86_64-uefi-minimal.iso`.
- Plasma live ISO packed and booted in QEMU (same live path; ZFS userspace present; SDDM starts). Artifact: `out/voidling-x86_64-uefi-plasma.iso`. ISO 9660 level 3 for the >4 GiB squashfs. Live squashfs ships `voidling-installer` / `install-voidling`.
- Product container `voidling-minimal:local` built with Podman (~177MB).
- Sealed OSTree dummy deploy; Fenestration package names queried on Void.

The qcow2 prototype **omits** the OSTree dracut module (flat ext4 root). The live ISO **omits** it too (squashfs + overlayfs). OSTree deployments **include** it. Do not mix those initramfs configs.

## Pipeline

| Area | Entry | Notes |
|------|--------|--------|
| VM | `tooling/image/boot-qemu.sh` | After `build-vm-uefi-qcow2.sh` |
| Live ISO | `install-live-dracut.sh` then `build-iso.sh`; `boot-qemu.sh --iso` | Extra step; not in default BOOTABLE initrd |
| OSTree deploy | `tooling/ostree/deploy-sysroot.sh` | Sealed trees skip `/etc` rewrite |
| Upgrade / rollback | `tooling/boot/voidling-upgrade.sh` / `voidling-rollback.sh` | Snapshot hook + deploy + menu |
| Disk install | `install-voidling.sh --target=disk --i-understand-this-wipes-disks` | Real mkfs when armed. Live ISO: `sudo voidling-installer` |
| Snapshots | `voidling-snapshot.sh restore` | `/var` only, not OSTree rollback |
| Sourcing | compose reads `extra-pkgs` | Local binpkgs `-R` first |
| First-boot | `tooling/firstboot/configure-system.sh` | Hostname/user/Flathub; LUKS/swap plan-only |

## Still not a shipping product

- Plasma qcow2 not built here (disk).
- Archive refs in `out/ostree-repo/` may still be unsealed until recomposed.
- LUKS/swap flags record a plan only.
- ARM back-burner. Git repo is yours to create.
