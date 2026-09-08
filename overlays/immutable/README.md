# Immutable overlay

Applied to every product rootfs before it is sealed for OSTree (`/usr/etc`).

## Mounts (xbps read-only)

`/usr/lib/voidling/mount-immutable.sh` (runit service `voidling-immutable`):

- remount `/usr` read-only
- bind-mount `/var/db/xbps` and `/var/cache/xbps` read-only

`xbps-install` / `xbps-remove` on the booted system then fail because they
cannot write the package database or `/usr`.

`usr/lib/ostree/prepare-root.conf` sets `ReadOnly=true` for `ostree-prepare-root`
when the initramfs supports it.

## Apps

`usr/lib/voidling/apps-policy` — Flatpak first, then Sourcing, Distrobox, AppImage.
