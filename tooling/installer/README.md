# Voidling installer (prototype)

Guided-in-spirit installer for an **immutable OSTree-deployed** Voidling system.
This is not Anaconda and not a drop-in replacement for [void-installer](https://github.com/void-linux/void-installer).

Default target is a **directory / sysroot** (`TARGET=dir`). That path never
partitions or formats a disk. Destructive disk work runs only when
`TARGET=disk` **and** `--i-understand-this-wipes-disks` are both set, and
`--dry-run` is not.

Full directory-vs-disk design: [docs/55-installer.md](../../docs/55-installer.md).

## User flow

1. Compose a variant and commit it (other tooling):

   ```bash
   bash tooling/compose/compose-minimal-rootfs.sh
   VARIANT=minimal bash tooling/ostree/commit-rootfs.sh
   ```

2. Run the **noninteractive** installer (preferred, testable):

   ```bash
   bash tooling/installer/install-voidling.sh
   # equivalent:
   TARGET=dir VARIANT=minimal FILESYSTEM=zfs bash tooling/installer/install-voidling.sh
   ```

3. Inspect the staging sysroot:

   ```
   out/install-staging/
     .voidling-install-staging
     plan.env
     layout.txt
     helpers/*.cmd
     sysroot/          # ostree admin sysroot stand-in
       boot/efi/
   ```

4. Optional guided menu (dialog if present, else a numbered menu):

   ```bash
   bash tooling/installer/voidling-installer
   ```

   The menu only collects `VARIANT`, `FILESYSTEM`, `TARGET`, and `DEST`, then
   execs `install-voidling.sh`. It refuses a non-tty stdin. Disk mode asks you
   to type `I UNDERSTAND THIS WIPES DISKS` before it will pass the danger flag.

   Live ISO: `sudo voidling-installer` (menu) or `sudo install-voidling` (flags).
   `build-iso.sh` copies these helpers into the squashfs only; the compose tree
   stays sealed and does not keep a copy.

## Relation to void-installer

| void-installer | Voidling prototype |
|----------------|-------------------|
| TUI over a live ISO | Menu or flags; directory mode first |
| `xbps-install` onto a mutable root | Precomposed OSTree ref / rootfs only |
| Filesystem + packages on the target | Filesystem choice; layout via `tooling/snapshots/` |
| GRUB from the new root | `tooling/boot/` contract (extra rollback entries later) |
| runit on Void | Unchanged: runit |

Spirit that is kept: choose variant, choose filesystem, confirm, then a linear
install. What is not kept: live package installation, locale/user/network
wizards, and ARM.

## Danger

**Disk mode wipes the named whole-disk device.** Exact flags:

```bash
bash tooling/installer/install-voidling.sh \
  --target=disk \
  --dest=/dev/disk/by-id/… \
  --i-understand-this-wipes-disks
```

Optional: `--filesystem=zfs` (default) or `--filesystem=btrfs`,
`--variant=minimal` (default) or `--variant=plasma`.

That combination (and not `--dry-run`) will:

1. Partition GPT: ESP 512 MiB FAT (`VOIDLING_EFI`) + remainder root
2. `mkfs.vfat` the ESP
3. Call `create-btrfs-layout.sh --apply` or `create-zfs-layout.sh --apply`
4. Mount `SYSROOT` and the ESP, then `deploy-sysroot.sh` and `install-bootloader.sh`

Safety checks (the command is refused):

- missing `--i-understand-this-wipes-disks`
- dest is `/`, `/boot`, `/usr`, `/etc`, `/var`, `/root`, `/home`, `/sys`,
  `/proc`, `/dev`, `/run`, or a path under those (except a `/dev/…` disk;
  `/home/user/…` is allowed as a directory staging path)
- dest is not a real block device (`-b`)
- dest is a partition (`lsblk TYPE=part`); a whole disk is required
- dest or any child is mounted
- dest backs a host mount (`/`, `/boot`, …)
- dest is smaller than 1024 MiB
- `OSTREE_REPO_DIR` is missing (refuses to wipe if deploy cannot run)

Rehearse without wiping:

```bash
bash tooling/installer/install-voidling.sh \
  --target=disk --dest=/dev/disk/by-id/… \
  --i-understand-this-wipes-disks --dry-run
```

Do not point directory-mode `--dest` at `/`, `/boot`, `/usr`, `/etc`, `/var`,
`/dev`, or other system paths. Directory mode will replace a previous tree only
if it contains the `.voidling-install-staging` marker (or is empty).

`TARGET=dir` remains the default. `SKIP_MKFS=1` stays forced in dir mode.

## Flags and environment

See `install-voidling.sh --help`. Locked prototype values:

- `TARGET_ARCH=x86_64`, `TARGET_LIBC=glibc`
- `VARIANT=minimal|plasma`
- `FILESYSTEM=btrfs|zfs`

ESP + root: 512 MiB FAT ESP, remainder btrfs or zfs.

## Helpers

| Helper | Path | Role |
|--------|------|------|
| Snapshots (dir) | `tooling/snapshots/prepare-install-layout.sh` | Placeholder dirs; never mkfs |
| Snapshots (disk apply) | `create-btrfs-layout.sh` / `create-zfs-layout.sh` `--apply` | `mkfs` + subvolumes/datasets |
| OSTree | `tooling/ostree/deploy-sysroot.sh` | `ostree admin` sysroot deploy from a precomposed ref |
| Boot | `tooling/boot/install-bootloader.sh` | GRUB/UKI into the ESP, room for rollback entries |
| First-boot | `tooling/firstboot/configure-system.sh` | Hostname, user, locale, NetworkManager, Flatpak (if present) |

If a helper **is** present and executable, directory mode runs it.
`prepare-install-layout.sh` refuses mkfs; disk apply therefore calls the
create-*-layout scripts with `--apply` and unsets `SKIP_MKFS`.

This installer does not run `xbps-install` on the target.

`--swap` and `--luks` only record a storage plan (default off). They do not
create swap or LUKS. Directory mode never requires LUKS.

Also stubbed: ARM, a production TUI, and actually applying swap/LUKS.

Contracts: [INTEGRATION.md](INTEGRATION.md).
