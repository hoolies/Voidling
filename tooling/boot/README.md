# Voidling boot menu + upgrade + rollback

Automatic GRUB/BLS boot entries for every OSTree deployment, plus CLIs that
deploy a new generation or make a previous deployment the default next boot.
Inspired by Fedora Atomic / rpm-ostree: rollback is **reboot into a retained
deployment**, not a live `/usr` mutation and not a ZFS/Btrfs snapshot.

This directory owns **bootloader metadata** and the **on-image upgrade /
rollback CLIs**. OSTree commits stay in `tooling/ostree/commit-rootfs.sh`.
Sysroot checkouts are produced by `tooling/ostree/deploy-sysroot.sh`, which
`voidling-upgrade.sh` calls. See [INTEGRATION.md](INTEGRATION.md).

## Upgrade vs rollback vs snapshot restore

These are three different operations. Do not substitute one for another.

| Action | Protects / changes | Activation | Tool |
|--------|--------------------|------------|------|
| **Upgrade** | New OSTree deployment becomes next-boot default; previous stay for rollback | Reboot | `voidling-upgrade.sh` |
| **Rollback** | Previous OSTree deployment becomes next-boot default | Reboot | `voidling-rollback.sh` + boot menu |
| **Snapshot restore** | Mutable `/var` only (`@var` / `rpool/var`) | Restore CLI (other agent) | `tooling/snapshots/` |

- **Upgrade** optionally pulls a ref, calls
  `tooling/snapshots/pre-upgrade-snapshot.sh` when that file is executable
  (does **not** reimplement `/var` snapshots), calls `deploy-sysroot.sh`,
  regenerates the boot menu, and prints the next-boot default. Dry-run is
  the default; pass `--apply` to write.
- **Rollback** is `ostree admin set-default` (or a BLS / `voidling-order`
  stub) plus menu regenerate. It does **not** roll back a ZFS/Btrfs snapshot
  and does **not** mutate `/usr`.
- **Snapshot restore** is owned by `tooling/snapshots/`. Rolling back an
  OSTree deployment does **not** restore `/var`. Restoring `/var` does
  **not** change the booted deployment.

No UEFI NVRAM write is performed by any tool here.

## Tools

| File | Role |
|------|------|
| `voidling-upgrade.sh` | Pull (optional), snapshot hook, deploy, regenerate menu |
| `voidling-rollback.sh` | List deployments; set default next boot |
| `generate-boot-menu.sh` | Read a sysroot, emit BLS + `grub.cfg` |
| `15_voidling` | `grub-mkconfig` drop-in (calls the generator) |
| `voidling-boot-lib.sh` | Shared discovery helpers (sourced, not run) |
| `ensure-secureboot-keys.sh` / `ensure-secureboot-tools.sh` | Secure Boot signing key + host tools (`SECURE-BOOT.md`) |
| `SECURE-BOOT.md` | Signed GRUB/kernel chain for the live ISO (`build-iso.sh --secure-boot`) |
| `LUKS-TPM2.md` | Opt-in clevis/TPM2 slot so a LUKS root asks once |

## Prototype (directory sysroot)

Default input: `out/sysroot/` (osname `voidling`).
Default output: `out/boot/grub.cfg` plus BLS under `out/boot/loader/entries/`.

```bash
# After ostree-deploy has populated out/sysroot:
bash tooling/boot/generate-boot-menu.sh
bash tooling/boot/generate-boot-menu.sh --list

# Upgrade a running or prototype image (dry-run default):
bash tooling/boot/voidling-upgrade.sh --variant=plasma
bash tooling/boot/voidling-upgrade.sh --apply --variant=plasma

# Make the previous deployment the default (index 1). Then reboot.
bash tooling/boot/voidling-rollback.sh --list
bash tooling/boot/voidling-rollback.sh
```

A self-contained fixture lives in `testdata/sysroot/` (two plasma-like
deployments). Useful when `out/sysroot` does not exist yet:

```bash
bash tooling/boot/generate-boot-menu.sh \
    --sysroot=tooling/boot/testdata/sysroot \
    --output-dir=/tmp/voidling-boot

bash tooling/boot/voidling-upgrade.sh \
    --sysroot=tooling/boot/testdata/sysroot \
    --filesystem=dir \
    --variant=plasma

bash tooling/boot/voidling-rollback.sh \
    --sysroot=tooling/boot/testdata/sysroot \
    --list
```

`--apply` against testdata will call the snapshot hook (dir backend) and
then fail at `deploy-sysroot.sh` unless a real archive repo is present.
Dry-run is enough to exercise the fixture.

Disk apply (`install-voidling.sh` with `--i-understand-this-wipes-disks`) sets
`APPLY_DISK=1` so `install-bootloader.sh` runs `grub-install` (removable EFI),
writes `EFI/BOOT/grub.cfg` via `voidling-grub-esp.sh`, and generates
`/boot/grub.cfg` with Btrfs paths under `/@/` when `FILESYSTEM=btrfs`.
No UEFI NVRAM write is performed (`--removable --no-nvram`).

## Upgrade CLI

`voidling-upgrade.sh` (install as `voidling-upgrade`):

1. Resolve `VARIANT` / `OSTREE_REF` (`voidling/x86_64/glibc/$VARIANT`).
   With neither flag, inherit the current default deployment’s origin.
2. Optionally `ostree pull` (`--pull`) into the sysroot repo.
3. If `tooling/snapshots/pre-upgrade-snapshot.sh` is executable, call it
   (`--apply` is forwarded only when this script is `--apply`).
4. Call `tooling/ostree/deploy-sysroot.sh` (sets `OSTREE_BOOTLOADER=none`).
5. Call `generate-boot-menu.sh`.
6. Print `NEXT_BOOT_DEFAULT=` (index 0) on stdout.

`commit-rootfs.sh` stays commit-only. The on-image / prototype sequence after
a new commit is **`deploy-sysroot.sh` then `generate-boot-menu.sh`**. This
script is that pair, plus the snapshot hook.

`RETAIN=1` by default so previous deployments remain rollback targets.

## Choice: BLS + generated GRUB menuentries

**Boot Loader Spec** files under `loader/entries/` are the canonical metadata
(same as libostree). Void’s `grub-x86_64-efi` may not ship a working `blscfg`
module, so the generator **also** writes explicit `menuentry` blocks.

- Standalone prototype: `out/boot/grub.cfg`
- Snippet to source from a real GRUB config: `out/boot/grub/grub-voidling.cfg`
- BLS: `out/boot/loader/entries/ostree-voidling-<checksum>.<serial>.conf`

Do not enable GRUB `blscfg` **and** these menuentries at once or the menu
duplicates.

## Installing on a real system

Two supported hooks (pick one; both consume the same BLS):

### 1. `grub-mkconfig` drop-in (preferred when bash is present)

Install:

- `/usr/libexec/voidling/generate-boot-menu.sh`
- `/usr/libexec/voidling/voidling-boot-lib.sh`
- `/usr/bin/voidling-upgrade` ← `voidling-upgrade.sh`
- `/usr/bin/voidling-rollback` ← `voidling-rollback.sh`
- `/etc/grub.d/15_voidling` (mode `0755`)

Then:

```bash
grub-mkconfig -o /boot/grub/grub.cfg
```

`15_voidling` guesses the sysroot (`/sysroot` if `/sysroot/ostree` exists,
else `/` if `/ostree/deploy` exists). Override with `VOIDLING_SYSROOT`.

Plasma images include bash. **Minimal** images use dash as `/bin/sh` and may
omit bash: generate the snippet on the installer/host (which has bash) and
use method 2.

### 2. Source a generated snippet from `/boot/grub/grub.cfg`

```grub
# /boot/grub/grub.cfg (excerpt)
insmod part_gpt
search --no-floppy --label VOIDLING_ROOT --set=root
source /boot/grub/grub-voidling.cfg
```

The installer or `generate-boot-menu.sh` writes `/boot/grub/grub-voidling.cfg`
and the BLS tree under `/boot/loader/entries/`. Re-run the generator after
every upgrade, deploy, or rollback. No NVRAM update is required.

## Kernel arguments

Each synthesized entry includes (placeholders until deploy/installer fill them):

```
root=UUID=VOIDLING-ROOT rw ostree=/ostree/boot.N/voidling/<bootcsum>/<serial> zswap.enabled=0
```

When `deploy-sysroot.sh` has already written BLS, we **reuse** its `options`
(including `KARG_OSTREE` and optional `init=…/ostree-prepare-root`). That
helper switch-roots into the deployment and execs runit (`/sbin/init`).
No `systemd.*` kargs are emitted.

- Override the root placeholder: `--root-karg="$KARG_ROOT"` from deploy stdout.
- Extra tokens: `--extra-kargs='quiet loglevel=3'`.

If `/boot` is on the root filesystem (current qcow2 seed), pass
`--boot-prefix=/boot` so GRUB `linux` paths become `/boot/ostree/...`.
BLS paths stay canonical (`/ostree/...`) relative to the `/boot` filesystem.

## Rollback CLI

`voidling-rollback.sh` (install as `voidling-rollback`):

1. Prefer `ostree admin --sysroot=… set-default INDEX` (libostree 2026.4+).
2. If that fails (non-root prototype, missing repo), rewrite
   `boot/loader/voidling-order` + BLS versions so the target sorts first.
3. Regenerate `grub.cfg`.

Never checks out or writes into a deployment’s `/usr`.
