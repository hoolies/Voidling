# GRUB / Btrfs OSTree boot contract

Product disk installs (and `build-ostree-qcow2.sh`) share one GRUB handoff.

## ESP (removable EFI)

`install-bootloader.sh` with `APPLY_DISK=1`:

1. `grub-install --target=x86_64-efi --removable --no-nvram`
2. `EFI/BOOT/grub.cfg` and `EFI/BOOT/BOOTX64.EFI` early config from
   `voidling-grub-esp.sh`

Btrfs early config (preferred when `ROOT_FS_UUID` is set):

```
search --no-floppy --fs-uuid <ROOT_FS_UUID> --set=root
configfile ($root)/@/boot/grub.cfg
```

Fallback without UUID: `search --label VOIDLING_ROOT`.

ZFS early config searches the pool label and loads `($root)/boot/grub.cfg`.

## Sysroot menu (`/boot/grub.cfg`)

`generate-boot-menu.sh` with `--root-subvol=@` (installer / upgrade / rollback
when the root is Btrfs):

- `search --fs-uuid …` (or label) then `set prefix=($root)/@/boot/grub`
- `linux` / `initrd` paths are `($root)/@/boot/ostree/...` (or real
  `/@/boot/vmlinuz-*` when OSTree left an absolute symlink)

Kernel args always include `zswap.enabled=0` and
`modprobe.blacklist=zswap`, plus `rootflags=subvol=@` on Btrfs.

## Kernel objects

`commit-rootfs.sh` hardlinks (or copies) `boot/vmlinuz-KVER` into
`usr/lib/modules/KVER/vmlinuz`. Absolute symlinks break GRUB on Btrfs.

## LUKS (optional)

When `--luks-passphrase-file` is used:

1. ESP early config runs `cryptomount -u <LUKS_UUID>` (GRUB passphrase #1).
2. Kernel args include `rd.luks.uuid=…`; dracut/cryptsetup may prompt again
   (passphrase #2) unless a keyfile/TPM unlock is added later.
3. Keyslots: PBKDF2 (500k iterations) for GRUB, plus an argon2id slot with the
   same passphrase for cryptsetup.

Persist `EXTRA_KARGS` (including `rd.luks.uuid` and `console=ttyS0`) in
`/etc/voidling/kargs` so `voidling-upgrade` keeps them.

## Checks

```bash
bash tooling/boot/test-esp-chain.sh
```
