# Filesystems and snapshots — implementation notes

Policy is locked in [27-filesystems-and-snapshots.md](27-filesystems-and-snapshots.md). This file is not a second policy.

The CLI, layout helpers, and tests live in `tooling/snapshots/`.

- Dry-run is the default. `--apply` runs `btrfs` / `zfs`.
- The `dir` backend records metadata under `SYSROOT/var/lib/voidling/snapshots/` and does not copy `/var`. Use it with `--sysroot` when no host pool or filesystem should change.
- ZFS `restore --apply` runs `zfs rollback -r`. It refuses when a newer snapshot of the same dataset is pinned. The named snapshot is kept.
- Btrfs `restore --apply` replaces live `@var` with a writable snapshot of `NAME` and leaves other snapshots in place.
- Upgrade callers use `pre-upgrade-snapshot.sh` only. Do not reimplement `create --type pre-upgrade` plus `prune` in `tooling/boot/` or `tooling/ostree/`.

Naming, `@var` / `rpool/var`, the separate restore CLI, pool name `rpool`, prune-on-the-pre-upgrade-hook, and `manual-user` retention are decided in the policy doc.
