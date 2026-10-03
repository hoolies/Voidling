# Boot / upgrade / rollback integration contract

This is the contract between **this directory** (`tooling/boot/`) and:

- `tooling/ostree/` (sysroot deploy — **`voidling-upgrade.sh` calls `deploy-sysroot.sh`**)
- `tooling/snapshots/` (pre-upgrade `/var` hook — **we call it; we do not implement it**)
- installer (bootloader install + real `root=` UUID/LABEL)
- image/qcow2 seed (GRUB EFI, kernel from Void `linux`)

We do **not** own `commit-rootfs.sh` internals, disk wiping, or snapshot
restore. After `commit-rootfs.sh` writes an archive-z2 ref, the on-image /
prototype path is **`deploy-sysroot.sh` then `generate-boot-menu.sh`**.
`voidling-upgrade.sh` is that pair (plus the snapshot hook).

## Locked product UX

- Every retained OSTree deployment is a boot-menu entry by default.
- CLI (`voidling-upgrade`) deploys a new generation and regenerates the menu.
- CLI (`voidling-rollback`) makes a previous deployment the default **next
  boot**. Activation is a reboot. `/usr` of the running tree is not mutated.
- Rollback is **not** a ZFS/Btrfs snapshot restore. `/var` snapshots are
  `tooling/snapshots/pre-upgrade-snapshot.sh`.
- Init is **runit**. No systemd as PID 1. No `systemd.*` kernel arguments.

## Names and refs (ostree-deploy must match)

| Item | Value |
|------|--------|
| osname / stateroot | `voidling` |
| Architecture (first) | `x86_64` + glibc |
| Ref pattern | `voidling/x86_64/glibc/$VARIANT` |
| Origin refspec | `voidling:voidling/x86_64/glibc/$VARIANT` (remote `voidling`) |
| Variants already committed | `minimal`, `plasma` (older `base` may exist) |
| Prototype sysroot | `out/sysroot/` |
| Prototype boot output | `out/boot/` |
| Deploy CLI | `tooling/ostree/deploy-sysroot.sh` (called by `voidling-upgrade.sh`) |
| Snapshot hook | `tooling/snapshots/pre-upgrade-snapshot.sh` (called if executable) |

Example refs:

- `voidling/x86_64/glibc/minimal`
- `voidling/x86_64/glibc/plasma`

## Expected sysroot layout

`ostree admin` conventions, rooted at `SYSROOT` (default `out/sysroot`):

```
$SYSROOT/
  ostree/
    repo/                                 # bare or bare-user (after pull from archive-z2)
    deploy/voidling/deploy/
      <checksum>.<serial>/                # checkout (immutable /usr)
      <checksum>.<serial>.origin          # keyfile, see below
    deploy/voidling/var/                  # shared /var (we do not touch)
    boot.0/voidling/<bootcsum>/<serial>/  # kernel farm (bootcsum ≠ commit)
    boot.1/voidling/<bootcsum>/<serial>/  # alternate boot version
  boot/
    loader -> loader.0                    # optional symlink; we accept loader/ too
    loader/entries/                       # BLS (we write; we also consume if present)
    loader/voidling-order                 # our stub default order (one id per line)
    loader/voidling-default               # first line = default id
    ostree/voidling-<bootcsum>/           # vmlinuz-* + initramfs-*.img
    grub.cfg                              # we write (prototype)
    grub/grub-voidling.cfg                # we write (source this from real grub.cfg)
```

Deployment id format: `<checksum>.<serial>` where `checksum` is the OSTree
commit SHA256 (64 hex chars) and `serial` is a non-negative integer (`0`, `1`, …).

### `.origin` file

Next to each deployment directory:

```
[origin]
refspec=voidling:voidling/x86_64/glibc/plasma
```

`baserefspec=` is also accepted. A bare `voidling/x86_64/glibc/$VARIANT` (no
remote prefix) is accepted too. The remote prefix is stripped for display.
If the file is missing, the generator falls back to
`voidling/x86_64/glibc/$VARIANT` (`VARIANT` default `unknown`).

### Kernel locations we search (in order)

1. `$SYSROOT/boot/ostree/voidling-<checksum>/vmlinuz-<kver>`
2. Any `$SYSROOT/boot/ostree/voidling-*/vmlinuz-<kver>`
3. `$deploy/usr/lib/modules/<kver>/vmlinuz` (+ `initramfs.img`) — Fedora/OSTree path
4. `$deploy/boot/vmlinuz-<kver>` — Void `linux` package path
5. Placeholders: `/ostree/voidling-BOOTCSUM/vmlinuz` and `initramfs.img`

`minimal` / `plasma` compose trees today often **have no kernel**. The
bootable seed (`compose-bootable-rootfs.sh`: `linux`, `grub-x86_64-efi`,
`dracut`) does. The generator still emits entries with `KVER` / `BOOTCSUM`
placeholders so deploy can land later.

**Ask of ostree-deploy:** copy or hardlink the deployment kernel into
`$SYSROOT/boot/ostree/voidling-<bootcsum>/` (libostree does this) **or** leave
kernels in `/usr/lib/modules/$kver/` inside the commit. Print the `ostree=`
karg you expect; we will emit the same shape.

### Boot version `N` in `ostree=/ostree/boot.N/...`

Resolved as:

1. `readlink $SYSROOT/boot/loader` → `loader.N` ⇒ `N`
2. Else `ostree/boot.1` exists and `ostree/boot.0` does not ⇒ `1`
3. Else `0`

Please keep `boot/loader` as a symlink to `loader.0` or `loader.1` when you
use OSTree’s dual bootversion scheme.

The `ostree=` path uses the **boot checksum** (`bootcsum`), which is often
not the commit SHA. We take it from existing BLS `options` when present,
else from `$SYSROOT/ostree/boot.N/voidling/<bootcsum>/<serial>/`, else we
fall back to the commit checksum (fixture / testdata).

## Kernel command line

**Prefer** the BLS `options` line / `KARGS` / `KARG_OSTREE` that
`deploy-sysroot.sh` already wrote. Typical shape (from that agent):

```
root=UUID=<root-uuid> rw ostree=/ostree/boot.N/voidling/<bootcsum>/<serial> zswap.enabled=0
```

They may also include:

```
init=/ostree/boot.N/voidling/<bootcsum>/<serial>/usr/lib/ostree/ostree-prepare-root
```

`ostree-prepare-root` is the libostree switch-root helper; it then execs
`/sbin/init` (**runit**) inside the deployment. We **preserve** that `init=`
when it is already in BLS. We never emit `systemd.*` kargs.

When synthesizing (no BLS yet, e.g. `testdata/`):

```
root=UUID=VOIDLING-ROOT rw ostree=/ostree/boot.N/voidling/<checksum-or-bootcsum>/<serial> zswap.enabled=0
```

| Token | Meaning |
|-------|---------|
| `root=…` | Installer must pass `--root-karg="$KARG_ROOT"` from deploy stdout (or `root=LABEL=VOIDLING_ROOT`). Our default placeholder is `root=UUID=VOIDLING-ROOT`. |
| `rw` | Sysroot is writable; the deployment `/usr` stays read-only via OSTree hardlinks / mount policy. |
| `ostree=/ostree/boot.N/voidling/<bootcsum>/<serial>` | libostree path. Initramfs / `ostree-prepare-root` must honor this. |

Optional extras via `--extra-kargs`.

### Initramfs

`tooling/initramfs/install-ostree-initramfs.sh` installs `98voidling-ostree`
and rebuilds `/boot/initramfs-<kver>.img` during `BOOTABLE=1` compose. That
module honors `ostree=` and switch-roots into the deployment, then execs
runit. This directory only emits the karg. Do not add a second ostree hook.

## How we discover deployments

In order of preference for **ordering** (index `0` = default next boot):

1. `$SYSROOT/boot/loader/voidling-order` (one `<checksum>.<serial>` per line)
2. `ostree admin --sysroot=$SYSROOT status` if it lists `voidling` rows
3. Directory walk of `ostree/deploy/voidling/deploy/*` (plus BLS-only leftovers)

BLS files we already wrote (or that ostree-deploy wrote) overlay `linux`,
`initrd`, `options`, and `title` when they match an `ostree=` karg or filename
`ostree-voidling-<checksum>.<serial>.conf`.

## What we write

Given `--sysroot` (default `out/sysroot`) and `--output-dir` (default
`out/boot` when the sysroot is the prototype path):

| Path | Content |
|------|---------|
| `$OUTPUT_DIR/loader/entries/ostree-voidling-<csum>.<serial>.conf` | BLS |
| `$OUTPUT_DIR/loader/entries.srel` | `ostree` |
| `$OUTPUT_DIR/loader/voidling-order` | default-first id list |
| `$OUTPUT_DIR/loader/voidling-default` | default id |
| `$OUTPUT_DIR/grub.cfg` | standalone GRUB menu (`default=0`, timeout 5) |
| `$OUTPUT_DIR/grub/grub-voidling.cfg` | menuentries only |

Unless `--no-sysroot-boot`, the same tree is mirrored to `$SYSROOT/boot/`.

BLS `options` stay spec-canonical (`linux /ostree/voidling-…`). GRUB
`linux`/`initrd` paths may gain `--boot-prefix=/boot` when `/boot` lives on
the root filesystem (qcow2 seed). Default prefix is empty (separate `/boot`
or GRUB `$root` already the boot fs).

## Upgrade contract

```bash
voidling-upgrade.sh --sysroot=$SYSROOT --variant=plasma
voidling-upgrade.sh --sysroot=$SYSROOT --apply --variant=plasma
voidling-upgrade.sh --sysroot=$SYSROOT --apply --ref=voidling/x86_64/glibc/plasma
voidling-upgrade.sh --sysroot=$SYSROOT --apply --pull --variant=plasma
```

Dry-run is the default. `--apply` writes.

Sequence (this script; do not reimplement in `commit-rootfs.sh`):

1. Resolve `VARIANT` / `OSTREE_REF`. If neither is given, inherit the
   current default deployment’s origin (`voidling/x86_64/glibc/$VARIANT`).
2. Optional `--pull`: `ostree --repo=$SYSROOT/ostree/repo pull` (then
   `pull-local` from `OSTREE_REPO_DIR` if the remote pull fails).
   `deploy-sysroot.sh` still pulls the archive when it runs.
3. If `tooling/snapshots/pre-upgrade-snapshot.sh` is **executable**, call
   it with `--sysroot` and `--filesystem` (and `--apply` only when this
   script is `--apply`). Skip if the file is missing or not executable.
   Do **not** reimplement `/var` snapshots here.
4. Call `tooling/ostree/deploy-sysroot.sh --sysroot --osname --ref` with
   `OSTREE_BOOTLOADER=none` and `RETAIN=1` by default (previous deployments
   stay as rollback targets).
5. Call `generate-boot-menu.sh` (BLS + `grub.cfg`).
6. Print `NEXT_BOOT_DEFAULT=` (index 0) on stdout. Also reprint
   `deploy-sysroot.sh` `KEY=value` lines when `--apply` succeeds.

`commit-rootfs.sh` remains commit-only. Callers that just committed a
rootfs should run **`deploy-sysroot.sh` then `generate-boot-menu.sh`**
(or `voidling-upgrade.sh --apply`).

Does **not** write UEFI NVRAM / BootOrder.

## Rollback contract

```bash
voidling-rollback.sh --sysroot=$SYSROOT          # default: --to=1 (previous)
voidling-rollback.sh --sysroot=$SYSROOT --list
voidling-rollback.sh --sysroot=$SYSROOT --to=2
```

Behavior:

1. **Does not** write into any deployment’s `/usr`, `/etc`, or `/var`.
2. Tries `ostree admin --sysroot=$SYSROOT set-default INDEX` (libostree 2026.4+).
3. On failure (typical non-root `out/sysroot` prototype): rewrites
   `voidling-order` / `voidling-default` and regenerates BLS + `grub.cfg` so
   the target is menu index 0 / highest BLS `version`.
4. Does **not** call `ostree admin undeploy` (that deletes a deployment).
5. Does **not** write UEFI NVRAM / BootOrder.
6. Does **not** restore a ZFS/Btrfs `/var` snapshot.

Installer and ostree-deploy should treat “default next boot” as **BLS order +
`ostree admin set-default`**, not as an EFI variable.

## How the installer should hook GRUB

GRUB is already used in the qcow2 seed (`grub-x86_64-efi`,
`grub-install --target=x86_64-efi --bootloader-id=Voidling`,
`grub-mkconfig -o /boot/grub/grub.cfg`).

After the first `ostree admin deploy`:

1. Run `generate-boot-menu.sh --sysroot=<target-sysroot> --root-karg=root=UUID=<root>`.
2. Either:
   - install `15_voidling` → `/etc/grub.d/15_voidling` and re-run `grub-mkconfig`, or
   - `source /boot/grub/grub-voidling.cfg` from the installed `/boot/grub/grub.cfg`.
3. Install `voidling-upgrade` and `voidling-rollback` into `$PATH` on the target.
4. Do **not** rely on `os-prober`. Do **not** require an NVRAM write for
   upgrade or rollback (extra EFI Boot#### entries are optional later).

`15_voidling` is bash. Host/installer generation covers **minimal** (no bash)
images: write the static snippet at deploy time.

## Commands ostree-deploy should print for us

`deploy-sysroot.sh` already prints `KEY=value` on **stdout**. We consume:

| Key | Use |
|-----|-----|
| `SYSROOT` | `--sysroot` |
| `OSNAME` | `--osname` (must be `voidling`) |
| `KARG_ROOT` | `--root-karg` (already includes `root=`) |
| `KARG_OSTREE` | must match BLS `ostree=` (bootcsum path) |
| `KARGS` | preferred full `options` line when regenerating would otherwise synthesize |
| `DEPLOYMENT_ID` | `<checksum>.<serial>` |

`voidling-upgrade.sh --apply` invokes `deploy-sysroot.sh`, then passes
`KARG_ROOT` into `generate-boot-menu.sh`. Direct generator callers may still
consume these keys themselves.

## What we will not do

- Edit `tooling/ostree/commit-rootfs.sh` internals, installer, image, compose,
  overlays, or `AGENTS.md` / `docs/50-mvp.md`.
- Reimplement `/var` snapshots (call `pre-upgrade-snapshot.sh` only).
- Treat rollback as a ZFS/Btrfs snapshot restore.
- Real UEFI firmware / NVRAM writes.
- Implement the dracut/ostree switch-root hook.

## Fixture

`testdata/sysroot/` is a two-deployment directory tree matching this contract
(`aaaaaaaa…aaaa.0` current, `bbbbbbbb…bbbb.0` previous, ref
`voidling/x86_64/glibc/plasma`). Use it when `out/sysroot` is empty.
`voidling-upgrade.sh` dry-run against this tree inherits `plasma` from the
origin and calls the snapshot hook without `--apply`.
