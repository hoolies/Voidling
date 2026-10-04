# Installer (directory vs disk)

The installer is **not** void-installer and **not** Anaconda. It deploys a
**precomposed OSTree ref**. It never runs `xbps-install` on the target.

Two modes:

| Mode | What it does | When you use it |
|------|----------------|-----------------|
| `TARGET=dir` (default) | Writes `out/install-staging/` and **runs** helpers against a directory sysroot. `SKIP_MKFS=1`. | Lab, CI, “did the contracts work?” |
| `TARGET=disk` without `--i-understand-this-wipes-disks` | Refused | — |
| `TARGET=disk` + danger flag + `--dry-run` | Prints the GPT/mkfs/helper plan; does not wipe | Rehearse |
| `TARGET=disk` + danger flag, not dry-run | GPT, `mkfs.vfat` ESP, FS layout `--apply`, mount SYSROOT+ESP, deploy, bootloader | Real install to a disposable whole disk |

Disk mode requires `--i-understand-this-wipes-disks` to mention a block
device. That flag **does** turn on formatting when `--dry-run` is not set.

## What a disk install does (when armed)

1. **Choose variant:** `minimal`, `plasma`, or `plasma-fenestration`
   (`voidling-installer` menu or `--variant=`).
2. **Choose filesystem:** `--filesystem=auto` (default) picks ZFS when the
   install medium has `zpool`+`zfs`, otherwise Btrfs; `zfs`/`btrfs` force it.
   Shipped ISOs are `WITH_ZFS=0`, so they install Btrfs. Not ext4 (the qcow2
   prototype uses ext4 only as a VM shortcut).
3. **GPT layout:**
   - Partition 1: ESP, FAT32, 512 MiB, label `VOIDLING_EFI` (FAT volume label
     truncated to 11 characters), mount `/boot/efi`
   - Partition 2: rest of disk, Btrfs or ZFS, product root
4. **Layout helpers** (`tooling/snapshots/`):
   - Dir mode calls `prepare-install-layout.sh` (never mkfs).
   - Disk apply calls `create-btrfs-layout.sh --apply` or
     `create-zfs-layout.sh --apply` (`prepare-install-layout.sh` refuses mkfs).
   - Btrfs: `@` (OSTree sysroot), `@var` (snapshotted), `@home` (not snapshotted
     by default), `@snapshots`
   - ZFS: `rpool/ROOT` (sysroot), `rpool/var` (snapshotted), `rpool/home` (not)
5. **OSTree deploy** (`deploy-sysroot.sh`): pull the archive repo into a bare
   sysroot, `ostree admin deploy` osname `voidling`, ref
   `voidling/x86_64/glibc/$VARIANT`. The composed tree has `/usr/etc` (no `/etc`).
6. **Bootloader** (`install-bootloader.sh`): GRUB EFI into the ESP, BLS +
   rollback menu entries. Extra slots left for previous deployments.
7. **Immutable mounts:** the `voidling-immutable` runit service remounts `/usr`
   and xbps db/cache read-only on first boot.
8. **Baseline** pinned `/var` snapshot (`create-baseline-snapshot.sh`); fails
   the install unless `VOIDLING_ALLOW_BASELINE_FAIL=1`.
9. **Reboot** into the new deployment.

Refused dests include `/`, `/boot`, `/usr`, `/etc`, `/var`, `/root`, `/home`,
and other system paths; partitions (need a whole disk); mounted devices; and
the disk that backs the host `/` or `/boot`. Missing `OSTREE_REPO_DIR` also
refuses to wipe.

Identity (hostname, user, locale) is collected by `voidling-installer` and
passed through to `configure-system.sh`. Disk apply with
`--luks-passphrase-file` formats LUKS2; `--luks-tpm2` needs a `WITH_TPM2=1`
tree and a TPM device. `--swap` creates `/var/swap/swapfile` (NOCOW on Btrfs).
zram (`voidling-zram`) is independent of `--swap`. ARM is still out of scope.

## What you run today

```bash
bash tooling/installer/install-voidling.sh
# VARIANT=minimal|plasma|plasma-fenestration  FILESYSTEM=zfs|btrfs|auto  TARGET=dir

bash tooling/installer/voidling-installer   # tty menu (dialog when present)
```

On a live ISO, the same commands are on PATH after boot (`sudo voidling-installer`,
or `sudo install-voidling` for flags). Live media includes `dialog`. Disk
install still needs a source OSTree repo (`OSTREE_REPO_DIR`); directory mode
does not.

Disk rehearsal (no mkfs):

```bash
bash tooling/installer/install-voidling.sh \
  --target=disk --dest=/dev/disk/by-id/... \
  --i-understand-this-wipes-disks --dry-run
```

Wipe a disposable whole disk:

```bash
bash tooling/installer/install-voidling.sh \
  --target=disk --dest=/dev/disk/by-id/... \
  --i-understand-this-wipes-disks
```

Contracts: `tooling/installer/INTEGRATION.md`.
