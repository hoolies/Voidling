# Compose rootfs (prototype)

Composes a Void Linux (glibc) root filesystem from **official Void repositories** into an output directory, without modifying the host system.

Variants are selected with `VARIANT` (or a preset script). Output path:

`out/rootfs-$TARGET_ARCH-$TARGET_LIBC-$VARIANT/`

## Requirements

- `xbps-install` available on the build machine

## Variants

Two product images. `BOOTABLE=1` adds kernel + EFI GRUB + dracut to the same variant.

| Variant | Preset | Intent |
|---------|--------|--------|
| `minimal` | `compose-minimal-rootfs.sh` | No DE, no window manager; POSIX `/bin/sh` (dash) |
| `plasma` | `compose-plasma-rootfs.sh` | Full KDE Plasma + Bourne_Again git_config experience |
| `plasma-fenestration` | `compose-fenestration-rootfs.sh` | Plasma plus Fenestration overlay |

### Plasma defaults

- Packages: Plasma stack, zsh+bash, vim, tmux, Alacritty, Helix, yazi, conky, glow, fuzzel, git, fd/fzf/bat/tree, NetworkManager, Flatpak, PipeWire, Nerd Fonts, sudo, Dolphin, …
- **Default browser:** Zen Browser (official tarball → `/usr/lib/zen-browser`)
- **Default file manager:** Dolphin
- **Default terminal:** Alacritty (`etc/xdg/kdeglobals`)
- Skel: `overlays/plasma/etc/skel` synced from Bourne_Again `git_config/.config` (`hoolies` function prefixes → `voidling`). XFCE/qtile configs are **not** copied.
- Default shell: **zsh** (bash also installed)
- Enabled services: dbus, elogind, NetworkManager, sddm, bluetoothd (when present)
- Refresh skel: `bash tooling/compose/sync-plasma-skel.sh`

### Fenestration

Optional Windows/gaming stack applied **on top of Plasma** (`overlays/fenestration/`). Compose:

```bash
bash tooling/compose/compose-fenestration-rootfs.sh
```

### Minimal package policy

- Install: `base-container ca-certificates` (`runit-void` comes with `base-container`)
- Ignore via `IGNOREPKGS` / `etc/xbps.d`: `glibc-locales`, `nvi`, `which`
- `/bin/sh` → `dash`; **no bash** in the image
- Locale stays C/POSIX (no `glibc-locales`)

## Run

From the repo root:

```bash
# Minimal (no DE)
bash tooling/compose/compose-minimal-rootfs.sh

# KDE Plasma (full experience)
bash tooling/compose/compose-plasma-rootfs.sh

# VM/ISO (same variants, plus kernel + GRUB)
bash tooling/compose/compose-bootable-rootfs.sh --variant=minimal
bash tooling/compose/compose-bootable-rootfs.sh --variant=plasma
```

Or call the shared implementation directly:

```bash
VARIANT=minimal bash tooling/compose/compose-rootfs.sh
```

Note: compose needs to run outside restrictive sandboxes because some XBPS
post-install scripts require capabilities that are blocked there.

## Bootable images (minimal or plasma)

`compose-bootable-rootfs.sh` is a wrapper: it sets `BOOTABLE=1` and calls the product preset. Output stays `out/rootfs-x86_64-glibc-minimal/` or `…-plasma/`.

```bash
bash tooling/compose/compose-bootable-rootfs.sh --variant=minimal
bash tooling/compose/compose-bootable-rootfs.sh --variant=plasma
```

After overlays, product presets **seal** the tree: immutable mounts overlay, then
`finalize-ostree-tree.sh` moves `/etc` → `/usr/etc` (OSTree-shaped commit).
Fenestration composes Plasma with `SKIP_SEAL=1`, then seals once at the end.

`SKIP_SEAL=1` skips both steps (used when this rootfs will get more xbps-install).

## Config

Environment variables:

- `VARIANT` (default: `minimal`)
- `TARGET_ARCH` (default: `x86_64`)
- `TARGET_LIBC` (default: `glibc`)
- `PKGS` (default: `base-container ca-certificates`)
- `IGNOREPKGS` (space-separated; written to `etc/xbps.d` before install)
- `OUT_DIR` (default: `<repo>/out`)
- `REPO_CURRENT` (default: `https://repo-default.voidlinux.org/current`)
- `REPO_CURRENT_NONFREE` (default: `https://repo-default.voidlinux.org/current/nonfree`)
