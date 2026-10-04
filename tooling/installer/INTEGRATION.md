# Installer integration contracts

The installer owns **orchestration only**. Snapshot policy, `ostree admin`
sysroot internals, and rollback boot entries belong to other agents. Match these
script names and environment variables.

All helpers are invoked as:

```bash
bash -- "$VOIDLING_ROOT/<helper>"
```

from the repo root context (`VOIDLING_ROOT` is the Voidling checkout). Helpers
must be executable. Missing helpers are recorded and skipped in **directory**
mode. Disk apply requires the layout, ostree, and boot helpers to exist.

Directory mode is the default and never wipes disks (`SKIP_MKFS=1`). Disk apply
runs only with `TARGET=disk`, `--i-understand-this-wipes-disks`, and no
`--dry-run`. `prepare-install-layout.sh` refuses mkfs, so disk apply calls
`create-btrfs-layout.sh --apply` or `create-zfs-layout.sh --apply` instead.

Shared environment on every helper invocation:

| Variable | Example | Meaning |
|----------|---------|---------|
| `VOIDLING_ROOT` | `/path/to/Voidling` | Repo root |
| `TARGET` / `INSTALL_MODE` | `dir` or `disk` | Install target kind |
| `DEST` | staging dir or `/dev/disk/by-id/...` | User destination |
| `DISK_DEST` | empty or block device | Set only for `TARGET=disk` |
| `SYSROOT` | `$WORK_DEST/sysroot` | OSTree sysroot path |
| `ESP_DIR` | `$SYSROOT/boot/efi` | ESP mount point |
| `ESP_PART` | `/dev/…p1` | ESP partition (disk apply) |
| `ROOT_PART` | `/dev/…p2` | Root partition (disk apply) |
| `VARIANT` | `minimal` or `plasma` | Image variant |
| `FILESYSTEM` | `btrfs` or `zfs` | Root filesystem choice |
| `TARGET_ARCH` | `x86_64` | Architecture |
| `TARGET_LIBC` | `glibc` | libc |
| `OSTREE_REPO_DIR` | `$OUT_DIR/ostree-repo` | Source archive repo |
| `OSTREE_REF` | `voidling/x86_64/glibc/minimal` | Ref to deploy |
| `OSTREE_OSNAME` | `voidling` | `ostree admin` osname |
| `ZPOOL_NAME` | `rpool` | ZFS pool name |
| `ESP_SIZE_MIB` | `512` | Planned ESP size |
| `ESP_LABEL` | `VOIDLING_EFI` | Planned ESP label |
| `ROOT_LABEL` | `VOIDLING_ROOT` | Planned root label |
| `ROOT_KARG` | `UUID=…` or `ZFS=rpool/ROOT` | `root=` value after format |
| `SKIP_MKFS` | `1` dir / `0` disk apply | Do not format devices when `1` |
| `APPLY_DISK` | `0` or `1` | Disk partition/mkfs/apply is armed |
| `DRY_RUN` | `0` or `1` | Plan only |
| `BOOT_ALLOW_EXTRA_ENTRIES` | `1` | Leave room for rollback entries |
| `BOOTLOADER` | `grub` | GRUB only (locked) |
| `BOOTLOADER_ID` | `Voidling` | EFI bootloader id |
| `SWAP` | `0` or `1` | Optional swap **plan** (default off; not created) |
| `LUKS` | `0` or `1` | Dir: plan only. Disk apply: LUKS2 when passphrase file set |
| `LUKS_TPM2` | `0` or `1` | Disk apply: clevis TPM2 bind after LUKS open |
| `VOIDLING_HOSTNAME` | `voidling` | First-boot hostname (do not use `HOSTNAME`) |
| `VOIDLING_USER` | `voidling` | First-boot login name |

Helpers should honor `SKIP_MKFS=1` and `DRY_RUN=1`. Do not run `xbps-install`
against the target.

Recorded replay files: `$WORK_DEST/helpers/<name>.cmd`.

---

## Snapshots — dir: `tooling/snapshots/prepare-install-layout.sh`

**Owner:** snapshots agent. The installer does **not** choose retention, pin
rules, or “last 3 per type”.

### Expected CLI

No required flags. Configuration is entirely via the environment above.

Suggested optional flags (if you add them, keep env as source of truth):

```
Usage: prepare-install-layout.sh [OPTION]...
Prepare install-time btrfs subvolumes or zfs datasets.

  -n, --dry-run         honor DRY_RUN=1
  -h, --help            display this help and exit
```

### Expected behavior

`FILESYSTEM=btrfs` (directory mode, `SKIP_MKFS=1`):

- Do not run `mkfs.btrfs`.
- Create only the install-time subvolume *layout names* the snapshots agent
  owns, under `SYSROOT` or as documented placeholders.

`FILESYSTEM=zfs` (directory mode, `SKIP_MKFS=1`):

- Do not run `zpool create` / `zfs create` on host pools.
- Suggested default dataset path: `${ZPOOL_NAME:-rpool}/ROOT`
- Export `ZPOOL_NAME` if you need a different pool name (installer passes
  through any pre-set `ZPOOL_NAME`).

`INSTALL_MODE=disk` apply (installer-owned, not this wrapper):

- The installer partitions GPT and `mkfs.vfat` the ESP.
- It then calls `create-btrfs-layout.sh --apply` or
  `create-zfs-layout.sh --apply` (this wrapper exits if `SKIP_MKFS` is unset).
- After `--apply`, the installer mounts `@` or `rpool/ROOT` at `SYSROOT` and
  the ESP at `ESP_DIR`.

Exit 0 on success, 1 on runtime failure, 2 on usage error.

### What the installer will not call

- Any snapshot create/prune/pin tool
- `tooling/snapshots/` scripts other than `prepare-install-layout.sh` (dir)
  and `create-btrfs-layout.sh` / `create-zfs-layout.sh` (disk apply)

Post-install hook: `tooling/snapshots/create-baseline-snapshot.sh` (pinned
`baseline` /var snapshot after firstboot on disk apply).
with the same env, after a successful deploy.

---

## OSTree deploy — `tooling/ostree/deploy-sysroot.sh`

**Owner:** ostree agent. Do not duplicate `ostree admin` layout in the installer.

### Expected CLI

```
Usage: deploy-sysroot.sh [OPTION]...
Deploy a precomposed OSTree ref into SYSROOT.

  -h, --help            display this help and exit
```

Environment (same table). Important keys: `SYSROOT`, `OSTREE_REPO_DIR`,
`OSTREE_REF`, `OSTREE_OSNAME`, `VARIANT`, `TARGET_ARCH`, `TARGET_LIBC`,
`DRY_RUN`, `ROOT_KARG`.

### Expected semantics (you implement; installer does not)

The installer expects this helper to perform the equivalent of:

```bash
ostree admin init-fs --modern -- "$SYSROOT"
ostree admin os-init --sysroot="$SYSROOT" -- "$OSTREE_OSNAME"
ostree pull-local --repo="$SYSROOT/ostree/repo" -- "$OSTREE_REPO_DIR" "$OSTREE_REF"
ostree admin deploy --sysroot="$SYSROOT" --os="$OSTREE_OSNAME" -- "$OSTREE_REF"
```

Notes:

- Source content is the **precomposed** ref from `tooling/ostree/commit-rootfs.sh`
  (`OSTREE_REF` default `voidling/x86_64/glibc/$VARIANT`).
- Do not `xbps-install` onto `SYSROOT`.
- `commit-rootfs.sh` uses archive-z2 repos; pull-local / add-repo is yours.
- Directory mode: `SYSROOT` is a directory (`out/install-staging/sysroot`), not
  a mounted block device.
- Disk apply: `SYSROOT` is the mounted `@` subvolume or `rpool/ROOT`.

Exit 0/1/2 as above. If `OSTREE_REPO_DIR` is missing, fail with a clear error
(the installer only warns in dir mode; disk apply refuses to wipe first).

---

## Boot / rollback — `tooling/boot/install-bootloader.sh`

**Owner:** boot/rollback agent. The installer installs a bootloader **slot**,
not the rollback menu itself.

### Expected CLI

```
Usage: install-bootloader.sh [OPTION]...
Install GRUB into the ESP for an OSTree sysroot.

  -h, --help            display this help and exit
```

Environment: `SYSROOT`, `ESP_DIR`, `BOOTLOADER=grub`,
`BOOTLOADER_ID` (`Voidling`), `BOOT_ALLOW_EXTRA_ENTRIES=1`, `TARGET_ARCH`,
`DRY_RUN`, `ROOT_KARG`.

### Expected semantics

- UEFI first (`x86_64-efi`), GRUB only (`docs/uki-decision.md`).
- Install into `ESP_DIR` (mounted at `/boot/efi` on a real disk).
- Keep a stable include/drop-in so extra entries can appear later without
  rewriting the installer, for example:
  - GRUB drop-in under `SYSROOT/etc/grub.d/` / `boot/grub/`
  - BLS under `SYSROOT/boot/loader/entries/`
- Do **not** require the rollback generator to exist at install time.
- Suggested later hook (not invoked today):
  `tooling/boot/add-rollback-entries.sh` with `SYSROOT`, `ESP_DIR`,
  `OSTREE_OSNAME`.

The installer never writes `grub.cfg` rollback entries itself.

Example GRUB-shaped command the boot agent may run (illustrative):

```bash
grub-install --target=x86_64-efi \
    --efi-directory="$ESP_DIR" \
    --boot-directory="$SYSROOT/boot" \
    --bootloader-id="$BOOTLOADER_ID"
```

---

## Call order

Directory mode:

1. `prepare-install-layout.sh` — placeholder dirs (no mkfs)
2. `deploy-sysroot.sh` — OSTree deployment into `SYSROOT`
3. `install-bootloader.sh` — bootloader on `ESP_DIR`
4. `tooling/firstboot/configure-system.sh` — hostname, user, locale, NM, Flatpak (if present)

Disk apply (`TARGET=disk` + `--i-understand-this-wipes-disks`, not `--dry-run`):

1. GPT via `sfdisk` (ESP 512 MiB EF00, remainder Linux)
2. `mkfs.vfat -F 32` on the ESP
3. Optional LUKS2 format/open (`--luks-passphrase-file`); optional `--luks-tpm2`
4. `create-btrfs-layout.sh --apply` or `create-zfs-layout.sh --apply`
5. Mount `@` or `rpool/ROOT` at `SYSROOT`, ESP at `ESP_DIR`
6. `deploy-sysroot.sh` + crypttab / `@home` fstab / persistent kargs
7. `install-bootloader.sh` (signs ESP when `SECURE_BOOT=1` and keys exist)
8. `configure-system.sh` (`--swap` remains plan-only; LUKS already applied)

---

## First-boot — `tooling/firstboot/configure-system.sh`

**Owner:** first-boot agent. Call this script when it exists; do not inline
hostname/user/locale/network here. Do not `xbps-install`.

### Expected CLI

```
Usage: configure-system.sh [OPTION]... [SYSROOT]
Configure hostname, a wheel/sudo user, locale, and NetworkManager in a SYSROOT.

  -s, --sysroot=PATH    default: SYSROOT
      --swap            record optional swap plan (default: off)
      --luks            record optional LUKS plan (default: off)
  -n, --dry-run         honor DRY_RUN=1
  -h, --help            display this help and exit
```

Installer invocations pass environment only (`SYSROOT`, `VARIANT`, `SWAP`,
`LUKS`, `DRY_RUN`, `VOIDLING_HOSTNAME`, `VOIDLING_USER`).

`--swap` is plan-only in directory mode; on disk apply it creates
`/var/swap/swapfile` (`SWAP_SIZE_MIB`, default 2048) plus fstab lines.
`--luks` is plan-only in directory mode; on disk apply the installer runs
`cryptsetup` when `--luks-passphrase-file` is set. Directory mode must not
require LUKS. zram (`voidling-zram`) is independent of `SWAP`.

Details: `tooling/firstboot/INTEGRATION.md`.

## Layout reminder (disk)

GPT:

1. ESP — 512 MiB — FAT32 — `VOIDLING_EFI` — `/boot/efi`
2. root — remainder — btrfs or zfs — `VOIDLING_ROOT` — `/`

## Compatibility

Wrappers at the contracted paths:

- `tooling/snapshots/prepare-install-layout.sh` → prints `create-btrfs-layout.sh` /
  `create-zfs-layout.sh` (never mkfs; dies if `SKIP_MKFS` is unset)
- Disk apply calls those create-* scripts with `--apply` directly
- `tooling/boot/install-bootloader.sh` → `generate-boot-menu.sh` + `15_voidling` drop-in

`deploy-sysroot.sh` accepts `SYSROOT` as an alias for `SYSROOT_DIR`, and
`OSTREE_OSNAME` as an alias for `OSNAME`. The installer also exports
`SYSROOT_DIR` and `OSNAME`.

If you must rename a script, keep a wrapper at the path above so this installer
does not need a coordinated edit. Env names in the table are the contract.
