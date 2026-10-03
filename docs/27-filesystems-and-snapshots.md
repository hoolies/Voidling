# Filesystems and snapshots (ZFS + Btrfs)

## Goals

- The OS ships with **ZFS** (default at install) and **Btrfs**.
- Installer **defaults to ZFS**; Btrfs remains a choice.
- System takes **automatic snapshots** before every major change.
- Snapshot retention:
  - Keep the **last 3 automatic snapshots per type**, and
  - Keep any **user-pinned** snapshots (must not be deleted).

## Decisions

- **Major change trigger:** snapshot **before** composing/applying a new immutable generation (`pre-upgrade`).
- **Pool name:** `rpool`.
- **Snapshot scope:** mutable system state only.
  - Btrfs: `@var`, mounted at `/var`. Snapshots are stored under `@snapshots/`.
  - ZFS: `rpool/var` (`rpool/var@<name>`).
- **`/home`:** separate dataset (`@home`, `rpool/home`). It is not snapshotted.
- **`/etc`:** lives on the OSTree deployment (`@`, `rpool/ROOT`). It is not part of the `/var` snapshot. Deployment rollback is what moves `/etc`.
- **Naming:** `voidling_<type>_<UTC-YYYYMMDDTHHMMSSZ>`  
  Example: `voidling_pre-upgrade_20260907T205900Z`  
  A second create of the same type in the same UTC second fails, because that name already exists.
- **Snapshot types** (retention is last 3 per type; pinned snapshots are kept):
  - `pre-upgrade`
  - `pre-fenestration-change`
  - `pre-sourcing-into-generation`
  - `manual-user` — not automatic, and not pruned
- **Prune:** `create` does not prune. `pre-upgrade-snapshot.sh` creates a `pre-upgrade` snapshot and then prunes. Other callers prune with `voidling-snapshot.sh prune` when they want retention applied.

## Layout

| Role | Btrfs | ZFS | Snapshotted |
|------|--------|-----|-------------|
| OSTree sysroot (`/`, including `/etc`) | `@` | `rpool/ROOT` | no |
| Mutable system state (`/var`) | `@var` | `rpool/var` | yes |
| User data (`/home`) | `@home` | `rpool/home` | no |
| Btrfs snapshot store | `@snapshots` | — | — |

Logs and container state under `/var` are inside `@var` / `rpool/var`, so they travel with that snapshot.

## Two rollbacks

Boot-menu rollback and snapshot restore stay separate CLIs. Use both when the generation and mutable system state must go back together.

| | Boot-menu rollback | Snapshot restore |
|--|--------------------|------------------|
| What moves | Next-boot OSTree deployment (`/usr` and that deployment’s `/etc`) | Live `@var` / `rpool/var` |
| Tool | Boot menu and `voidling-rollback.sh` | `voidling-snapshot.sh restore NAME` |
| `/home` | Left in place | Left in place |
| Activation | Reboot | `restore --apply` on the running system |

`ostree admin undeploy` removes a deployment. It does not restore `/var`.

After a failed generation:

1. Boot the previous deployment (boot menu or `voidling-rollback.sh`).
2. Restore the `pre-upgrade` snapshot:

```bash
voidling-snapshot.sh --apply restore voidling_pre-upgrade_YYYYMMDDTHHMMSSZ
```

Dry-run is the default for the snapshot CLI. Implementation notes (the `dir` backend, pin rules, ZFS `rollback -r`) live in `tooling/snapshots/README.md`.
