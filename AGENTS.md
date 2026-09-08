# Working agreements (Voidling)

## Locked decisions

- **Packages**: consume **unchanged** official Void Linux `.xbps` binaries.
- **Init**: **runit** (no systemd as PID 1).
- **Immutability**: immutable host; `xbps` is **read-only** on the running system.
- **Update backend**: OSTree-style commits/deployments.
- **Rollback UX**: boot menu entries by default + CLI tool.
- **Architectures**: `x86_64` glibc. ARM glibc is **back-burner** (do not implement).
- **Apps priority**: Flatpak first (Flathub) → Sourcing → Distrobox → AppImage.
- **xbps**: read-only on the running host, **enforced by mounts** (`/usr`, `/var/db/xbps`, `/var/cache/xbps`).
- **Compose trees**: `/usr/etc` (no `/etc`) so OSTree deploy does not rewrite the commit.
- **Optional**: Fenestration — Windows compatibility **without Steam**.
- **Git**: owner creates the repo; do not `git init`.
- **Filesystems**: **ZFS default** at install; Btrfs still a choice. Snapshots before major changes; keep last 3 per type + user-pinned.

## Vocabulary

- **Sourcing**: xbps-source build workflow that outputs either next immutable generation, OCI image, or Flatpak.
- **Fenestration**: optional Windows compatibility **without Steam**.

## Repo layout (initial)

- `docs/`: token-saving project notes / decisions
- `tooling/`: prototype compose / build / publish scripts

## Image variants (rootfs + OSTree)

Two product images. Kernel + GRUB is `BOOTABLE=1` on the same variant (not a third flavor).

| Variant | Intent | Rootfs | OSTree ref |
|---------|--------|--------|------------|
| `minimal` | No DE and no window manager; POSIX `/bin/sh` (dash); ignores locales/nvi/which | `out/rootfs-x86_64-glibc-minimal/` | `voidling/x86_64/glibc/minimal` |
| `plasma` | Full KDE Plasma; zsh + Bourne_Again git_config; Alacritty/Zen/Dolphin | `out/rootfs-x86_64-glibc-plasma/` | `voidling/x86_64/glibc/plasma` |
| `plasma-fenestration` | Optional Plasma plus Windows/gaming stack | `out/rootfs-x86_64-glibc-plasma-fenestration/` | `voidling/x86_64/glibc/plasma-fenestration` |

Presets: `tooling/compose/compose-minimal-rootfs.sh`, `tooling/compose/compose-plasma-rootfs.sh`, `tooling/compose/compose-fenestration-rootfs.sh`. VM/ISO: `BOOTABLE=1` or `compose-bootable-rootfs.sh --variant=minimal|plasma`.

Prototype follow-ons: `tooling/image/` (minimal qcow2 and live ISO booted), `tooling/initramfs/`, `tooling/boot/voidling-upgrade.sh`, `tooling/installer/` (disk apply behind danger flag), `tooling/firstboot/`, `tooling/snapshots/` (restore), `tooling/sourcing/` (compose extras wired), `tooling/container/` (`voidling-minimal:local` built).


