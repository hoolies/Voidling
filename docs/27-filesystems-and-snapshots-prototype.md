# Filesystems and snapshots — prototype defaults

Implementation: `tooling/snapshots/` (do not treat this file as a lock).
Policy lock remains `docs/27-filesystems-and-snapshots.md`.

## Prototype defaults

- **Naming:** `voidling_<type>_<UTC-YYYYMMDDTHHMMSSZ>`
- **Btrfs:** snapshot `@var`; `@home` is separate and not snapshotted by default; snapshots land in `@snapshots/`
- **ZFS:** snapshot `rpool/var`; `rpool/home` is not snapshotted by default
- **Retention:** last 3 automatic snapshots per type; pinned never deleted; `manual-user` is not pruned
- **Rollback:** snapshots protect mutable system state only. They are **not** OSTree deployment rollback (boot menu) and **not** `ostree admin undeploy`.
- **Restore CLI:** `tooling/snapshots/voidling-snapshot.sh restore NAME` (dry-run default; `--apply` rolls back `@var` / `rpool/var`). Pinned snapshots are never deleted. Upgrade callers must use `tooling/snapshots/pre-upgrade-snapshot.sh`.

## Open questions

1. Confirm or replace the naming scheme.
2. Confirm `@var` / `rpool/var` as the only system-only source (`/etc`, containers, logs).
3. How (if at all) snapshot restore (`voidling-snapshot.sh restore`) appears next to OSTree boot-menu rollback / `ostree admin undeploy`. Prototype: separate CLIs.
4. ZFS pool name if not `rpool`; Btrfs toplevel mount on a live host.
5. Whether `create` should always `prune`, and whether `manual-user` should ever expire.
