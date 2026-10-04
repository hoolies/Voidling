# Working agreements (Voidling)

## Locked decisions

- **Packages**: consume **unchanged** official Void Linux `.xbps` binaries.
- **Init**: **runit** (no systemd as PID 1).
- **Immutability**: immutable host; `xbps` is **read-only** on the running system.
- **Update backend**: OSTree-style commits/deployments.
- **Rollback UX**: boot menu entries by default + CLI tool.
- **Bootloader**: **GRUB + OSTree BLS only** (no UKI, sd-boot, or shim). See `docs/uki-decision.md`.
- **Architectures**: `x86_64` glibc. ARM glibc is **back-burner** (do not implement).
- **Apps priority**: Flatpak first (Flathub) → Sourcing → Distrobox → AppImage.
- **xbps**: read-only on the running host, **enforced by mounts** (`/usr`, `/var/db/xbps`, `/var/cache/xbps`).
- **Compose trees**: `/usr/etc` (no `/etc`) so OSTree deploy does not rewrite the commit.
- **Optional**: Fenestration — Windows compatibility **without Steam**.
- **Git**: owner creates the repo; do not `git init`.
- **Filesystems**: ZFS preferred when the install medium ships it, Btrfs otherwise (`--filesystem=auto`; shipped ISOs are `WITH_ZFS=0`, so they install Btrfs). Snapshots before major changes; keep last 3 per type + user-pinned.
- **Credentials**: lab login `voidling`/`voidling` on images and live ISO; live ISO root has no password. Installed systems force replacing the lab user on first login; root access policy `--root-access=locked|password|none` (default `locked`).
- **Supply chain**: OSTree commits are ed25519-signed when `out/ostree-keys` exists (`OSTREE_SIGN=auto`); releases use `VOIDLING_RELEASE=1` / `OSTREE_SIGN=1` (no unsigned fallback). The public key ships in the tree. Secure Boot: ISO (`build-iso.sh --secure-boot`), compose kernel signing (`SECURE_BOOT=1`), installed ESP when keys are on the installing host. Private keys never enter git.
- **Shell**: every script passes `bash tooling/ci.sh` (shellcheck, shfmt, unit tests) before commit.

## Vocabulary

- **Sourcing**: xbps-source build workflow that outputs either next immutable generation, OCI image, or Flatpak.
- **Fenestration**: optional Windows compatibility **without Steam**.

## Repo layout (initial)

- `docs/`: token-saving project notes / decisions (`60-build-and-release.md` = build order)
- `tooling/`: compose / ostree / initramfs / image / installer / firstboot / boot / snapshots / sourcing / container; `tooling/ci.sh` is the lint + unit-test gate
- `overlays/`: files applied onto composed trees (`immutable`, `initramfs`, `live`, plasma look)
- `out/`: build artifacts and host-local keys (git-ignored)

## Image variants (rootfs + OSTree)

Three product images. Kernel + GRUB is `BOOTABLE=1` on the same variant (not a separate flavor).

| Variant | Intent | Rootfs | OSTree ref |
|---------|--------|--------|------------|
| `minimal` | No DE and no window manager; POSIX `/bin/sh` (dash); ignores locales/nvi/which | `out/rootfs-x86_64-glibc-minimal/` | `voidling/x86_64/glibc/minimal` |
| `plasma` | Full KDE Plasma; zsh + Bourne_Again git_config; Alacritty/Zen/Dolphin | `out/rootfs-x86_64-glibc-plasma/` | `voidling/x86_64/glibc/plasma` |
| `plasma-fenestration` | Optional Plasma plus Windows/gaming stack | `out/rootfs-x86_64-glibc-plasma-fenestration/` | `voidling/x86_64/glibc/plasma-fenestration` |

Presets: `tooling/compose/compose-minimal-rootfs.sh`, `tooling/compose/compose-plasma-rootfs.sh`, `tooling/compose/compose-fenestration-rootfs.sh`. VM/ISO: `BOOTABLE=1` or `compose-bootable-rootfs.sh --variant=minimal|plasma|plasma-fenestration`.

Prototype follow-ons: `tooling/image/` (minimal qcow2 and live ISO booted), `tooling/initramfs/`, `tooling/boot/voidling-upgrade.sh`, `tooling/installer/` (disk apply behind danger flag), `tooling/firstboot/`, `tooling/snapshots/` (restore), `tooling/sourcing/` (compose extras wired), `tooling/container/` (`voidling-minimal:local` built).


