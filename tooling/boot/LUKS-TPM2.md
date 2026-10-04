# LUKS root: one prompt with TPM2 (opt-in)

Default LUKS installs ask twice: GRUB `cryptomount` (PBKDF2 slot, because
Void GRUB has no Argon2) and then the initramfs `crypt` module (argon2id
slot). `--luks-tpm2` removes the second prompt by sealing a third keyslot
to the machine's TPM2 with clevis. GRUB still asks once.

## Pieces

| Where | What |
|-------|------|
| compose | `WITH_TPM2=1` adds `clevis` (pulls `tpm2-tools`, `jose`, `luksmeta`) to the bootable tree |
| initramfs | `install-ostree-initramfs.sh` copies `51-voidling-tpm2.conf` when the tree has `clevis-decrypt-tpm2`: `add_dracutmodules+=" clevis-pin-tpm2 "`, TPM drivers. Clevis' dracut module has a non-systemd path (`initqueue/settled` unlocker) that runs `clevis luks unlock` before `cryptroot-ask` prompts |
| installer | `--luks-tpm2` (env `LUKS_TPM2=1`) after `cryptsetup open`: `clevis luks bind -k <pass> -d <root-part> tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'`; `--tpm2-pcrs=LIST` overrides the PCRs |
| plan | `LUKS_TPM2=` recorded in `plan.env` / `etc/voidling/storage-plan.env` |

## Build and install

```sh
WITH_TPM2=1 BOOTABLE=1 bash tooling/compose/compose-minimal-rootfs.sh
VARIANT=minimal bash tooling/ostree/commit-rootfs.sh
sudo bash tooling/image/install-live-dracut.sh --rootfs out/rootfs-x86_64-glibc-minimal
sudo bash tooling/image/build-iso.sh --variant=minimal

# on the target (live ISO), TPM2 present as /dev/tpmrm0:
sudo install-voidling --target=disk --i-understand-this-wipes-disks \
    --dest=/dev/nvme0n1 --luks-passphrase-file=/root/pass --luks-tpm2
```

Requirements on the installing host: `clevis` in PATH (the live ISO is the
minimal tree, so it must be a `WITH_TPM2=1` compose) and `/dev/tpmrm0`.
Shipped product ISOs stay `WITH_TPM2=0`; `voidling-installer` only offers
TPM2 when clevis is in the tree and a TPM device (or `TPM2TOOLS_TCTI`) is
visible.
The installer refuses `--luks-tpm2` otherwise.

## Policy

- PCR 7 (default) binds to the Secure Boot state. Changing firmware keys
  or booting an unsigned loader invalidates the TPM slot; the passphrase
  slots still open the disk, so the system is never locked out.
- Add `0,2,4,7` for a stricter firmware + bootloader measurement at the
  cost of re-binding after firmware updates (`clevis luks regen`).
- The passphrase stays the recovery path. `clevis luks list -d <dev>` shows
  the TPM slot; `clevis luks unbind -d <dev> -s N` removes it.
- Keep the installed tree at `WITH_TPM2=1`; an upgrade to a tree without
  clevis in the initramfs falls back to the passphrase prompt (nothing
  breaks, the second prompt simply returns).

## Testing

```sh
# Empty PCR policy (host bind + same swtpm state in QEMU):
sudo bash tooling/image/test-luks-tpm2-boot.sh

# Production-shaped PCR 7: bind inside the guest, then reboot:
sudo bash tooling/image/test-luks-tpm2-pcr7-guest.sh

# Suite (skip with --skip-luks-tpm2 / --skip-luks-tpm2-pcr7):
sudo bash tooling/image/smoke-all.sh
```

`test-luks-tpm2-boot.sh` uses an empty PCR list so host-side clevis bind and
guest unlock share one swtpm state. `test-luks-tpm2-pcr7-guest.sh` binds PCR
7 **in the guest** (correct for Secure Boot / firmware PCR interaction).
`boot-qemu.sh --tpm` attaches `tpm-tis`.
