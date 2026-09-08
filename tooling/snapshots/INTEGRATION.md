# Snapshot integration points

Call `voidling-snapshot.sh create --type …` **before** the mutation. Snapshots
cover mutable system state only. They do **not** replace OSTree deployment
rollback (boot menu / ostree-deploy CLI).

Dry-run is default. Production callers must pass `--apply` once the target
filesystem exists.

## Installer

1. User chooses **ZFS** or **Btrfs**.
2. Run the matching layout helper (still dry-run unless installing):

   ```bash
   tooling/snapshots/create-btrfs-layout.sh --apply DEVICE /mnt/voidling-btrfs
   # then mount @ → target /, @var → target /var, @home → target /home

   tooling/snapshots/create-zfs-layout.sh --apply --mount-prefix /mnt/target DEVICE
   ```

3. After first boot (or at the end of install), optional baseline:

   ```bash
   tooling/snapshots/voidling-snapshot.sh --apply --filesystem btrfs \
       --btrfs-top /mnt/voidling-btrfs \
       create --type manual-user --label 'post-install' --pin
   ```

   or `--filesystem zfs --zfs-dataset rpool/var`.

Do not snapshot `@home` / `rpool/home` by default.

## OSTree deploy / upgrade

Before composing or applying a new immutable generation:

```bash
tooling/snapshots/pre-upgrade-snapshot.sh --apply --sysroot / \
    --filesystem auto
```

Equivalent explicit call:

```bash
tooling/snapshots/voidling-snapshot.sh --apply create --type pre-upgrade
tooling/snapshots/voidling-snapshot.sh --apply prune
```

`--type` **must** be `pre-upgrade`.

This hook is the **only** snapshot call site the upgrade CLI should
invoke. Do not reimplement `create --type pre-upgrade` + `prune` in
`tooling/boot/` or `tooling/ostree/`.

## Restore vs OSTree undeploy

These are independent. One does not do the other.

| Action | Tool | Mutates |
|--------|------|---------|
| Snapshot `/var` before upgrade | `pre-upgrade-snapshot.sh` | `@var` / `rpool/var` snapshot only |
| Restore mutable system state | `voidling-snapshot.sh restore NAME` | live `@var` / `rpool/var` |
| Roll back the booted generation | boot menu / `voidling-rollback.sh` | next-boot OSTree deployment |
| Delete a deployment | `ostree admin undeploy` / `tooling/ostree/undeploy.sh` | OSTree deployments |

`restore` rolls **`@var` / `rpool/var`** back to `NAME`. It does **not**
undeploy, set-default, or change `/usr`. `ostree admin undeploy` does
**not** restore `/var`.

After a failed generation, pair them if both trees need to go back:

```bash
# 1. boot the previous deployment (OSTree; other tooling)
# 2. restore mutable state taken by the pre-upgrade hook
tooling/snapshots/voidling-snapshot.sh --apply \
    restore voidling_pre-upgrade_YYYYMMDDTHHMMSSZ
```

Dry-run is the default. `--apply` executes `btrfs` / `zfs rollback`.
ZFS rollback `-r` forgets **newer unpinned** snapshots of the same
dataset; it **refuses** if a newer snapshot is pinned. The target
snapshot itself is kept. Btrfs/dir restore replace live `@var` and
leave other snapshots in place.

```bash
tooling/snapshots/voidling-snapshot.sh list --type pre-upgrade
tooling/snapshots/voidling-snapshot.sh restore NAME
tooling/snapshots/voidling-snapshot.sh --apply restore NAME
```

## Fenestration

Before applying a Fenestration change (enable, disable, or package-set
update that will land in the next generation):

```bash
tooling/snapshots/voidling-snapshot.sh --apply \
    create --type pre-fenestration-change
```

Then prune when convenient (or share the pre-upgrade hook if the change
is delivered only as a new OSTree generation — in that case `pre-upgrade`
is the required trigger; `pre-fenestration-change` is additional context).

## Sourcing

Before sourcing packages **into a generation** (xbps-src / containerized
build whose output is the next immutable tree):

```bash
tooling/snapshots/voidling-snapshot.sh --apply \
    create --type pre-sourcing-into-generation
```

Do not snapshot for sourcing that only produces an OCI image or Flatpak
and does not change host `/var`.

## Manual user snapshots

```bash
tooling/snapshots/voidling-snapshot.sh --apply \
    create --type manual-user --label 'before I touch things' --pin
```

`manual-user` is never pruned. `--pin` is still useful so a later explicit
delete (if added) would have to unpin first.

## Pin / unpin / prune / restore

```bash
tooling/snapshots/voidling-snapshot.sh --apply pin NAME
tooling/snapshots/voidling-snapshot.sh --apply unpin NAME
tooling/snapshots/voidling-snapshot.sh --apply prune
tooling/snapshots/voidling-snapshot.sh --apply restore NAME
```

Prune keeps the last 3 **unpinned** automatic snapshots per type and never
deletes pinned names. Restore also refuses to delete pinned names (ZFS
rollback will not run if a newer snapshot is pinned).

## Suggested flags per host

| Host FS | Flags |
|---------|--------|
| Btrfs | `--filesystem btrfs --btrfs-top <toplevel> --btrfs-subvol @var --btrfs-snapdir @snapshots` |
| ZFS | `--filesystem zfs --zfs-dataset rpool/var` |
| Lab / CI | `--filesystem dir --sysroot <tmp>` |
