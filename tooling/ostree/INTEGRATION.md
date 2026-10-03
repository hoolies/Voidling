# OSTree sysroot integration

Contract between `tooling/ostree/` and the **installer** and **boot/rollback** agents.

This directory does **not** partition disks, install GRUB, or take ZFS snapshots.

## Ownership

| Agent | Calls | Must not |
|-------|--------|----------|
| Compose | `tooling/compose/*.sh` | touch sysroots |
| Commit | `commit-rootfs.sh` | deploy or write `/boot` |
| **This tree** | `deploy-sysroot.sh`, `undeploy.sh` | GRUB, disk wipe, snapshots |
| Installer | mount target → `deploy-sysroot.sh` | invent a second checkout layout |
| Boot / rollback | consume `KARG_*` + BLS; switch default | implement deploy |

## Constants

| Name | Value |
|------|--------|
| osname / stateroot | `voidling` |
| remote | `voidling` (`file://` to the archive repo, `--no-gpg-verify`) |
| origin refspec | `voidling:voidling/x86_64/glibc/<variant>` |
| refs | `voidling/x86_64/glibc/{minimal,plasma,plasma-fenestration}` (legacy `…/base`) |
| source repo | `out/ostree-repo/` (`archive-z2`) |
| prototype sysroot | `out/sysroot/` |
| sysroot repo mode | `bare` (root) or `bare-user` (non-root) |

## Installer

### Sequence

1. Partition and format (installer-owned). Remember the **root filesystem UUID or LABEL**.
2. Mount the target root at `$SYSROOT` (for example `/mnt`). Mount ESP at `$SYSROOT/boot` or `$SYSROOT/boot/efi` as the boot agent requires. This script only needs the sysroot mount.
3. Ensure a commit exists (`VARIANT=… tooling/ostree/commit-rootfs.sh`) or copy `out/ostree-repo/` onto the install media.
4. Deploy:

```bash
SYSROOT_DIR="$SYSROOT" \
VARIANT=plasma \
ROOT_KARG="UUID=${ROOT_UUID}" \
EXTRA_KARGS="rw zswap.enabled=0" \
bash tooling/ostree/deploy-sysroot.sh
```

Equivalent flags: `--sysroot="$SYSROOT" --osname=voidling --ref=voidling/x86_64/glibc/plasma`.

5. Parse **stdout** (`KEY=value`, one per line). Ignore stderr.
6. Hand `KARG_ROOT`, `KARG_OSTREE`, and/or `KARGS` to the boot agent.
7. Do not copy the archive-z2 repo over ` $SYSROOT/ostree/repo`. The deploy script already pulled into a bare repo there.

### First install vs later update

- First bootable disk: `init-fs` + `os-init` + `deploy` (what this script does when the sysroot is empty).
- Later image update on an existing Voidling sysroot: same script against the mounted sysroot. OSTree keeps the previous deployment as rollback unless you pass `RETAIN=1` (keep all) or undeploy extras.
- Switch default: `ostree admin --sysroot="$SYSROOT" set-default INDEX` (boot agent / updater).
- Remove a deployment: `bash tooling/ostree/undeploy.sh --sysroot="$SYSROOT" INDEX`.

### Writable islands

| Path | Where it lives |
|------|----------------|
| `/usr` | deployment checkout — **treat as read-only** after deploy |
| `/etc` | `$SYSROOT/ostree/deploy/voidling/deploy/<id>/etc` (copied from commit `/usr/etc`) |
| `/var` | `$SYSROOT/ostree/deploy/voidling/var` (shared) |
| `/home` | sysroot `/home` from `init-fs`, or `/var/home` if the boot agent bind-mounts it |

Installer user-creation and machine-id belong in deployment `/etc` and stateroot `/var`, not in `/usr`.

This script does **not** remount `/usr` or lock xbps. Compose ships the `voidling-immutable` runit service (immutable overlay) that remounts `/usr` and `/var/db/xbps` + `/var/cache/xbps` read-only at boot. That service is another agent’s job.

## Boot / rollback agent

### What this script already wrote

- BLS drop-in under `$SYSROOT/boot/loader/entries/ostree-*.conf` (and `loader.N` while swapping)
- `ostree/boot.N/<osname>/<bootcsum>/<serial>/`
- Kernel (real or placeholder) under `$SYSROOT/boot/ostree/<osname>-<bootcsum>/`

`OSTREE_BOOTLOADER` defaults to `none`. **You** install GRUB (or another BLS consumer) and point it at those entries. Do not expect `grub-mkconfig` from this directory.

### Kernel arguments

Always consume the printed values after deploy. Typical shape:

```
root=UUID=<root-uuid>
rw
init=/ostree/boot.1/voidling/<bootcsum>/<serial>/usr/lib/ostree/ostree-prepare-root
ostree=/ostree/boot.1/voidling/<bootcsum>/<serial>
```

- Replace `ROOT_KARG` at deploy time with the real installed root (`UUID=…` or `LABEL=VOIDLING_ROOT`).
- `ostree=` is the switch/rollback handle. Each deployment has its own `boot.N` + bootcsum path.
- `ostree admin --sysroot=$SYSROOT status` lists deployments (index 0 = default).
- Rollback: `ostree admin --sysroot=$SYSROOT set-default <index>` then regenerate the bootloader menu from BLS. Optionally `undeploy.sh` the broken index after a successful boot.

Placeholder `vmlinuz-0.0.0-voidling-placeholder` is **not** bootable. BOOTABLE compose puts a real kernel at `/usr/lib/modules/$kver/vmlinuz`; `deploy-sysroot.sh` then defaults `KERNEL_PLACEHOLDER=0` and deploys the source commit as-is.

### Suggested status command

```bash
ostree admin --sysroot="$SYSROOT" status
ostree admin --sysroot="$SYSROOT" status --json
```

JSON fields used by this layout: `checksum`, `serial`, `stateroot`, `refspec`, `index`.

## stdout contract (`deploy-sysroot.sh`)

| Key | Meaning |
|-----|---------|
| `SYSROOT` | Absolute sysroot path |
| `OSNAME` | `voidling` |
| `OSTREE_REF` | Branch deployed (logical) |
| `ORIGIN` | `voidling:<ref>` |
| `SOURCE_COMMIT` | Commit pulled from the archive |
| `DEPLOY_COMMIT` | Tree actually deployed (may be derived) |
| `DEPLOYMENT` | `…/ostree/deploy/voidling/deploy/<checksum>.<serial>` |
| `DEPLOYMENT_ID` | `<checksum>.<serial>` |
| `DEPLOY_ETC` | Deployment `/etc` |
| `SHARED_VAR` | Stateroot `/var` |
| `ETC_NORMALIZED` | `yes` if `/etc` was rewritten to `/usr/etc` (old commits only) |
| `KERNEL_PLACEHOLDER_USED` | `yes` if a dummy vmlinuz was added |
| `SEALED_TREE` | `yes` if the source commit has `/usr/etc` and no `/etc` |
| `KARG_ROOT` | `root=…` (boot agent) |
| `KARG_OSTREE` | `ostree=…` (boot agent) |
| `KARGS` | Full BLS `options` line when available |

## Direct `ostree admin` (no wrapper)

```bash
mkdir -p -- "$SYSROOT"
ostree admin init-fs "$SYSROOT"
ostree admin os-init --sysroot="$SYSROOT" voidling
ostree --repo="$SYSROOT/ostree/repo" remote add --if-not-exists --no-gpg-verify \
    voidling "file://${ARCHIVE_REPO}"
ostree --repo="$SYSROOT/ostree/repo" pull voidling voidling/x86_64/glibc/minimal
# Sealed compose commits already have /usr/etc and (when BOOTABLE) a kernel.
# Old archive commits still need deploy-sysroot.sh's NORMALIZE_ETC fallback.
export OSTREE_BOOTLOADER=none
ostree admin --sysroot="$SYSROOT" deploy --os=voidling \
    --karg=root=UUID=… --karg=rw \
    voidling:voidling/x86_64/glibc/minimal
```

If `file://` pull fails, `ostree --repo="$SYSROOT/ostree/repo" pull-local "$ARCHIVE_REPO" REF`.

## Limitations

- archive-z2 source must be **pulled** into the sysroot’s bare repo.
- Sealed trees (`/usr/etc`, no `/etc`) deploy without a derived commit. `NORMALIZE_ETC` is still required for old commits that only have `/etc`.
- `KERNEL_PLACEHOLDER` stays a fallback for trees without `/usr/lib/modules/*/vmlinuz`. A placeholder kernel is not bootable.
- This directory does not start `voidling-immutable` or remount xbps paths.
- Non-root / sandboxed `bare` deploys often fail; use root on the target or `bare-user` for layout experiments.
- No bootloader menu, no ESP formatting, no snapshot integration.
- `init-fs` PATH must exist; do not pass `--` before that PATH.
- Keep `OSTREE_BOOTLOADER=none` so libostree does not rewrite GRUB.
