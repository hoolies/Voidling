# Filesystem snapshots (prototype)

System-only snapshot automation for Voidling. Ships with **ZFS and Btrfs**
layouts; the installer chooses one. This directory is the prototype CLI and
the helpers the installer can call.

Locked policy lives in `docs/27-filesystems-and-snapshots.md`. CLI behavior
that is not product policy is summarized in
`docs/27-filesystems-and-snapshots-prototype.md`.

## What this is (and is not)

These snapshots protect **mutable system state** (`/var`, Btrfs `@var`,
ZFS `rpool/var`). They are **not** a substitute for OSTree deployment
rollback.

| Mechanism | Protects | UX |
|-----------|----------|----|
| OSTree deployment rollback | Immutable `/usr` (and the booted generation) | Boot menu + `voidling-rollback.sh` / `ostree admin undeploy` |
| Filesystem snapshots | Mutable system state on `@var` / `rpool/var` | This CLI (`list` / `restore`) |

Rolling back an OSTree deployment does **not** restore `/var`. Restoring a
`/var` snapshot does **not** change the booted deployment and is **not**
`ostree admin undeploy`. Pair them when both the generation and mutable
state must go back. They stay separate CLIs: the boot menu switches the
deployment, and `restore` rolls back `@var` / `rpool/var`. Neither touches
`/home`.

**Not snapshotted by default:** `@home` / `rpool/home`.

## Snapshot types

| Type | When | Automatic? |
|------|------|------------|
| `pre-upgrade` | Before composing/applying a new immutable generation | yes |
| `pre-fenestration-change` | Before applying a Fenestration change | yes |
| `pre-sourcing-into-generation` | Before sourcing packages into a generation | yes |
| `manual-user` | User-requested | no (never pruned) |

Retention: last **3** automatic snapshots **per type**. **Pinned** snapshots
are never deleted. `manual-user` is not automatic and is never pruned.

## Naming

```
voidling_<type>_<UTC-YYYYMMDDTHHMMSSZ>
```

Example: `voidling_pre-upgrade_20260907T205900Z`

## Where system-only lives

| Filesystem | Snapshotted | Not snapshotted by default |
|------------|-------------|----------------------------|
| Btrfs | `@var` (mounted at `/var`); snapshots under `@snapshots/` | `@home` |
| ZFS | `rpool/var`; snapshot `rpool/var@<name>` | `rpool/home` |
| `dir` (auto-detect fallback) | metadata-only index under `SYSROOT/var/lib/voidling/snapshots/` | n/a |

`/etc` is on the OSTree sysroot (`@`, `rpool/ROOT`), so deployment rollback
moves it. A `/var` snapshot does not.

The `dir` backend is a **directory prototype**: it records snapshot metadata
and a `MANIFEST`. It does **not** copy `/var`. Use it with `--sysroot` in
this repo without touching host zpools or btrfs.

## Dry-run vs `--apply`

**Dry-run is the default.** Real `btrfs` / `zfs` / `zpool` / `mkfs.btrfs`
commands are printed and are only executed with `--apply`.

Layout helpers also refuse `--apply` when the device is already mounted,
when the Btrfs mountpoint is `/`, or when the ZFS pool name already exists.

## Scripts

| Script | Role |
|--------|------|
| `voidling-snapshot.sh` | create / list / prune / pin / unpin / restore |
| `create-btrfs-layout.sh` | print (or apply) Btrfs subvolume recipe |
| `create-zfs-layout.sh` | print (or apply) ZFS dataset recipe |
| `pre-upgrade-snapshot.sh` | hook: `create --type pre-upgrade` then `prune` |
| `test-voidling-snapshot.sh` | dir-backend create/list/prune/pin/restore tests |

See `INTEGRATION.md` for who should call which `--type`.

## CLI

```bash
tooling/snapshots/voidling-snapshot.sh --help
```

```bash
# Directory prototype (safe on this machine)
sysroot="$(mktemp -d)"
tooling/snapshots/voidling-snapshot.sh \
    --sysroot "$sysroot" --filesystem dir --apply \
    create --type pre-upgrade --label 'before generation'

tooling/snapshots/voidling-snapshot.sh --sysroot "$sysroot" list
tooling/snapshots/voidling-snapshot.sh --sysroot "$sysroot" --apply prune
tooling/snapshots/voidling-snapshot.sh --sysroot "$sysroot" --apply \
    pin voidling_pre-upgrade_YYYYMMDDTHHMMSSZ
tooling/snapshots/voidling-snapshot.sh --sysroot "$sysroot" --apply \
    restore voidling_pre-upgrade_YYYYMMDDTHHMMSSZ
```

```bash
# Print real Btrfs/ZFS commands (no host mutation)
tooling/snapshots/voidling-snapshot.sh \
    --filesystem btrfs --btrfs-top /mnt/voidling-btrfs \
    create --type pre-upgrade

tooling/snapshots/voidling-snapshot.sh \
    --filesystem zfs --zfs-dataset rpool/var \
    create --type pre-fenestration-change
```

`--filesystem auto` (default) uses `findmnt` on `--sysroot`: `btrfs` or
`zfs` if that is the mount type, otherwise `dir`.

### Environment

| Variable | Meaning |
|----------|---------|
| `VOIDLING_SYSROOT` | default `--sysroot` |
| `VOIDLING_FILESYSTEM` | default `--filesystem` |
| `VOIDLING_ZFS_DATASET` | default `--zfs-dataset` (`rpool/var`) |
| `VOIDLING_BTRFS_TOP` | default `--btrfs-top` |
| `VOIDLING_BTRFS_SUBVOL` | default `--btrfs-subvol` (`@var`) |
| `VOIDLING_BTRFS_SNAPDIR` | default `--btrfs-snapdir` (`@snapshots`) |
| `VOIDLING_SNAPSHOT_TS` | override UTC stamp in the name (tests / collision) |

## Layout helpers

```bash
tooling/snapshots/create-btrfs-layout.sh /dev/disk/by-id/… /mnt/voidling-btrfs
tooling/snapshots/create-zfs-layout.sh /dev/disk/by-id/…
tooling/snapshots/create-zfs-layout.sh --pool rpool --mount-prefix /mnt/target /dev/disk/by-id/…
```

Default is dry-run (prints `mkfs.btrfs` / `zpool create` / `zfs create` /
`btrfs subvolume create`). Pass `--apply` only on a disposable device.

## Pre-upgrade hook

```bash
tooling/snapshots/pre-upgrade-snapshot.sh --sysroot / --filesystem auto
```

Call this **before** OSTree deploy/upgrade. This is the hook the upgrade
CLI should execute; do not reimplement it. Forwards `--apply`, `--sysroot`,
`--filesystem`, dataset/subvol flags, `--pin`, and `--label` to
`voidling-snapshot.sh`.

## Restore

```bash
tooling/snapshots/voidling-snapshot.sh --sysroot "$sysroot" restore NAME
tooling/snapshots/voidling-snapshot.sh --apply restore NAME
```

`--apply` rolls live `@var` (Btrfs: delete + writable snapshot) or
`rpool/var` (ZFS: `zfs rollback -r`) to `NAME`. Dry-run prints those
commands. The named snapshot is kept. Pinned snapshots are never
deleted: ZFS restore refuses when a **newer** snapshot of the same
dataset is pinned (rollback `-r` would destroy it).

The `dir` backend records `SYSROOT/var/lib/voidling/snapshots/last-restore`
and does **not** copy `/var`.

`restore` is not OSTree undeploy. See `INTEGRATION.md`.

## Metadata

Index (source of truth for `list` / `prune` / `pin` / `restore`):

```
$SYSROOT/var/lib/voidling/snapshots/records/<name>
```

Directory-backend instance (prototype only):

```
$SYSROOT/var/lib/voidling/snapshots/instances/<name>/MANIFEST
```

Last successful restore marker:

```
$SYSROOT/var/lib/voidling/snapshots/last-restore
```

Snapshots created outside this tool are invisible to prune/pin/restore.

## Policy

Naming, scope, retention, and the split between boot-menu rollback and
`restore` are locked in `docs/27-filesystems-and-snapshots.md`. This README
describes the CLI that implements that lock. A second create of the same
type in the same UTC second fails (`snapshot already exists`). There is no
`delete` subcommand; `manual-user` and pinned snapshots are kept.
