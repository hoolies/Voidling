# Filesystems and snapshots (ZFS + Btrfs)

## Goals

- The OS ships with **ZFS** (default at install) and **Btrfs**.
- Installer **defaults to ZFS**; Btrfs remains a choice.
- System takes **automatic snapshots** before every major change.
- Snapshot retention:
  - Keep the **last 3 automatic snapshots per type**, and
  - Keep any **user-pinned** snapshots (must not be deleted).

## Decisions captured

- **Major change trigger:** snapshot **before** composing/applying a new immutable generation (**pre-upgrade**).
- **Snapshot scope:** **system-only** (i.e., the mutable system state on an immutable host; not user home by default).
- **Snapshot types (retention is last 3 per type + user-pinned never deleted):**
  - `pre-upgrade`
  - `pre-fenestration-change`
  - `pre-sourcing-into-generation`
  - `manual-user`

## Open details (do not assume yet)

- Snapshot naming scheme.
- Where “system-only” lives concretely in your final layout (e.g. which subvolumes/datasets correspond to mutable state).
- How snapshots integrate with rollback UX (boot menu entries vs manual restore).

