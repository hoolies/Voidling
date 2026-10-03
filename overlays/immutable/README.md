# Immutable overlay

Applied to every product rootfs before it is sealed for OSTree (`/usr/etc`).

## Mounts (xbps read-only)

`/usr/lib/voidling/mount-immutable.sh` (runit service `voidling-immutable`):

- bind-mount `/usr` onto itself, then remount that mount read-only (works when `/usr` is only a directory on the live overlay)
- bind-mount `/var/db/xbps` and `/var/cache/xbps` read-only

`xbps-install` / `xbps-remove` on the booted system then fail because they
cannot write the package database or `/usr`.

`usr/lib/ostree/prepare-root.conf` sets `ReadOnly=true` for `ostree-prepare-root`
when the initramfs supports it.

## Apps

`usr/lib/voidling/apps-policy` — Flatpak first, then Sourcing, Distrobox, AppImage.

## Memory

`/usr/lib/voidling/setup-zram.sh` (runit service `voidling-zram`):

- zram swap at priority 100, compressor zstd (lz4 if zstd is missing)
- size is half of RAM, capped at 8 GiB
- `vm.swappiness=180` and `vm.page-cluster=0` (`etc/sysctl.d/zz-voidling-zram.conf`)
- zswap forced off (`zswap.enabled=0` on the kernel command line, and the sysfs knob when it exists)
- when zram swap is active and the ZFS module is already loaded, `zfs_arc_max` is half of the RAM left after the zram cap, and only when that value is at least 64 MiB

Disk `--swap` stays a recorded install plan. This service does not create a swap partition or swap file. A later disk swap device needs a priority below 100.
