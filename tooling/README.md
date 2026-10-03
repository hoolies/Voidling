# Tooling (prototype)

Prototype pipeline:

1. Compose a Void (glibc) root filesystem from official `.xbps` repositories.
2. Commit the tree into a local OSTree repository.
3. (Optional) Deploy that commit into a sysroot, generate a rollback boot menu, build a VM/ISO, or stage an install.

Nothing here is considered stable yet.

## Variants (rootfs + OSTree)

| Variant | Compose | Rootfs | OSTree ref |
|---------|---------|--------|------------|
| `minimal` | `tooling/compose/compose-minimal-rootfs.sh` | `out/rootfs-x86_64-glibc-minimal/` | `voidling/x86_64/glibc/minimal` |
| `plasma` | `tooling/compose/compose-plasma-rootfs.sh` | `out/rootfs-x86_64-glibc-plasma/` | `voidling/x86_64/glibc/plasma` |
| `plasma-fenestration` | `tooling/compose/compose-fenestration-rootfs.sh` | `out/rootfs-x86_64-glibc-plasma-fenestration/` | `voidling/x86_64/glibc/plasma-fenestration` |

Minimal is **no desktop and no window manager**. Container seed: `base-container ca-certificates`, dash `/bin/sh`. VM/ISO: `BOOTABLE=1` (kernel + GRUB).

Plasma is the **full KDE experience**: zsh + Bourne_Again git_config skel, Alacritty, Zen, Dolphin. VM/ISO: `BOOTABLE=1`.

## Quick start

```bash
# Note: compose needs to run outside Cursor sandboxing because some XBPS
# post-install scripts require capabilities that are blocked in the sandbox.
bash tooling/compose/compose-minimal-rootfs.sh
VARIANT=minimal bash tooling/ostree/commit-rootfs.sh

bash tooling/compose/compose-plasma-rootfs.sh
VARIANT=plasma bash tooling/ostree/commit-rootfs.sh
```

Shared repo: `out/ostree-repo/`

## Other prototypes

| Area | Entry |
|------|--------|
| VM qcow2 / ISO | `tooling/image/README.md` |
| Product container / Distrobox | `tooling/container/README.md` |
| Installer (directory mode) | `tooling/installer/README.md` |
| OSTree sysroot deploy | `tooling/ostree/README.md` |
| Rollback boot menu | `tooling/boot/README.md` |
| ZFS/Btrfs snapshots | `tooling/snapshots/README.md` |
| Sourcing | `tooling/sourcing/README.md` |
| First-boot extras | `tooling/firstboot/README.md` |
| Secure Boot (live ISO, on/off) | `tooling/boot/SECURE-BOOT.md` |
| LUKS single prompt via TPM2 | `tooling/boot/LUKS-TPM2.md` |
| Build order / release | `docs/60-build-and-release.md` |
| Lint + unit tests | `bash tooling/ci.sh` (`--lint-only`, `--tests-only`, `--fix`) |
| Reclaim `out/` space | `tooling/image/clean-out.sh` (dry run; `--apply`) |
