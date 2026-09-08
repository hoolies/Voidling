# Fenestration integration (hooks only)

This overlay and the compose scripts do **not** implement the installer, OSTree commit tool, or snapshot tool. Those stay in their existing owners.

## Variant and OSTree

| Item | Value |
|------|--------|
| Variant | `plasma-fenestration` |
| Rootfs | `out/rootfs-x86_64-glibc-plasma-fenestration/` |
| OSTree ref | `voidling/x86_64/glibc/plasma-fenestration` |

Commit with the existing helper (do not change `commit-rootfs.sh`):

```bash
VARIANT=plasma-fenestration bash tooling/ostree/commit-rootfs.sh
```

Compose **extends** Plasma: `compose-fenestration-rootfs.sh` runs `compose-plasma-rootfs.sh`, copies that rootfs, then `xbps-install`s Fenestration extras. `PKGS` on the Fenestration preset is extras only.

## Feature detection

A deployed generation has Fenestration if `/etc/voidling/fenestration` exists (`enabled=1`, `variant=plasma-fenestration`).

## Snapshot hook — `pre-fenestration-change`

Documented hook only. Do not implement the snapshot tool here.

When Fenestration is enabled, disabled, or its image package set changes, the snapshot owner should take a **system-only** snapshot of type `pre-fenestration-change` **before** composing/applying the new immutable generation.

Retention (already locked in `docs/27-filesystems-and-snapshots.md`): last 3 automatic snapshots per type + user-pinned never deleted.

Suggested call site (future snapshot CLI, names illustrative):

```bash
# before compose-fenestration-rootfs.sh / deploy of plasma-fenestration
voidling-snapshot create --type pre-fenestration-change
```

Related types (other owners): `pre-upgrade`, `pre-sourcing-into-generation`, `manual-user`.

## Sourcing

Sourcing (xbps-src / containerized build) must not mutate the live immutable host.

If the user sources extra Windows/gaming packages:

- Output **next immutable generation** (typical for Fenestration extras).
- Fenestration remains an image feature: extras land in the composed `plasma-fenestration` tree, then OSTree deploy.
- `pre-sourcing-into-generation` still applies when sourcing is the trigger; if the change is specifically “turn Fenestration on/off or replace its seed”, also take `pre-fenestration-change`.

Do not treat Sourcing as live `xbps-install` of Wine on the booted system. Steam is not part of Fenestration.

## Installer (later)

Optional checkbox, not implemented:

- Off → deploy `plasma` (or `minimal`).
- On → deploy `plasma-fenestration`.

No live install path. Changing the checkbox after install is a new generation (and the `pre-fenestration-change` hook).

## Host invariants

- `/usr` is not mutated on the running host.
- `xbps` is read-only on the running host.
- Extra repos at compose time: `-R` current, current/nonfree, current/multilib, current/multilib/nonfree (see `compose-rootfs.sh` plus Fenestration’s two multilib URLs).
