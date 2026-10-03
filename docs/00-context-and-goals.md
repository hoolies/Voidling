# Context and goals

## Aim

Build a **new Linux distribution** that:

- Uses **Void Linux’s packaging ecosystem** (XBPS binaries, `void-packages` / xbps-src as appropriate).
- Presents an **immutable, image-style OS** comparable in *user experience* to **Bazzite** (read-only core, atomic updates, rollback, clear separation of system vs config vs state vs apps).
- Keeps **`xbps` read-only on the running host**, **enforced by mounts** (`/usr` plus xbps db/cache).
- Supports apps **Flatpak first** (Flathub), then Sourcing, then Distrobox, then AppImage.
- Supports optional **Fenestration**: Windows compatibility **without Steam** (Wine/Lutris in the image; Bottles/Heroic as Flatpaks).
- Ships with **ZFS and Btrfs** and allows the user to choose at install time, with automatic snapshots and retention.

## Architectural note (do not skip)

**Bazzite’s implementation** is **Fedora Atomic + rpm-ostree + OSTree + RPM**. That stack is **not** something you “drop Void packages into” unchanged.

- **Void** = **xbps** + its own packaging policy and rootfs layout.
- **Immutability / atomicity** in the Bazzite family = **OSTree (or related) deployment model** + usually **pre-composed base images** + defined semantics for `/usr`, `/etc`, `/var`, `/home`.

Your project needs an explicit decision: **how** you produce and update an immutable rootfs **while** consuming Void-built artifacts (e.g. compose into an image, OSTree from xbps root, btrfs/A-B images, erofs + updater, etc.). Treat “like Bazzite” as **UX and reliability goals**, not as “copy rpm-ostree.”

## Decisions (locked in)

- **Update backend**: OSTree-style commits and deployments (atomic switch + rollback).
- **Architectures / libc**: `x86_64` + glibc now. **ARM + glibc is back-burner** (do not implement).
- **Rollback UX**: automatic boot menu entries by default + a CLI tool.
- **Installer target**: similar in spirit to `void-installer`; disk wipe is gated (see `docs/55-installer.md`).
- **Apps priority**: Flatpak first, then Sourcing, then Distrobox, then AppImage.
- **Compose trees**: OSTree-shaped (`/usr/etc`, no `/etc` in the committed rootfs).
- **Git**: the human owner creates the Voidling git repo; agents do not `git init`.

## Non-goals (do not re-litigate)

- Steam in the Fenestration image.
- Live `xbps-install` / `xbps-remove` on the booted host.
- ARM images (until taken off the back burner).

Disk `mkfs` runs only for `TARGET=disk` with `--i-understand-this-wipes-disks`. Directory mode never formats a disk.
