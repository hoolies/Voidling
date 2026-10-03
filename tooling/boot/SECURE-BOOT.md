# Secure Boot (live ISO, opt-in)

Voidling ships **no Microsoft-signed shim** (locked decision: unchanged official
Void binaries only, and Void does not package shim). Secure Boot therefore
works with a **Voidling-owned key** that the machine owner enrolls once.

Toggle: `SECURE_BOOT=0` (default, unsigned ISO) or `SECURE_BOOT=1` /
`--secure-boot` on `tooling/image/build-iso.sh`.

## Chain

| Stage | Mechanism | Signed with |
|-------|-----------|-------------|
| Firmware → `EFI/BOOT/BOOTX64.EFI` | UEFI db check (Authenticode) | `voidling-sb.key` via `sbsign` |
| GRUB → embedded `grub.cfg` | GRUB `pgp` verifier, `check_signatures=enforce` | `voidling-grub` GPG key |
| GRUB → `/boot/vmlinuz`, `/boot/initrd` | GRUB `pgp` verifier (`*.sig` on the ISO) | `voidling-grub` GPG key |
| Kernel | also Authenticode-signed (`sbsign`) for firmware/shim loaders | `voidling-sb.key` |

GRUB is built standalone (`grub-mkstandalone --disable-shim-lock --sbat ... --pubkey ...`),
so no shim protocol is required and every module `grub.cfg` needs is built
into the signed image (no unsigned `insmod` from the memdisk). The kernel
reports `Secure boot enabled` on the console when the firmware enforced it.

`SECURE_BOOT_GPG=0` drops the GRUB-side verification (firmware still checks
GRUB itself); keep it at `1` unless debugging.

## Key material

`tooling/boot/ensure-secureboot-keys.sh` creates `out/secureboot-keys/`:

| File | Purpose |
|------|---------|
| `voidling-sb.key` | RSA-2048 private key (0600). Never ships, never commit. |
| `voidling-sb.crt` / `.cer` | Certificate PEM / DER. The `.cer` is what firmware menus import. |
| `voidling-sb.esl` / `.auth` | EFI signature list and self-signed authenticated update (efitools) for KeyTool / setup-mode enrollment. |
| `voidling-sb.guid` | Owner GUID used in the signature list. |
| `voidling-grub.gpg` | OpenPGP public key embedded into GRUB. |
| `gnupg/` | GPG home with the private GRUB signing key (0700). Never ships. |

`tooling/boot/ensure-secureboot-tools.sh` installs `sbsigntool` and `efitools`
into `out/hosttools/` with an unprivileged `xbps-install -r` when they are not
on `PATH`.

The ISO carries only public material under `EFI/voidling/keys/` (also inside
the El Torito FAT image so firmware file browsers can reach it).

## Enrolling on real hardware

1. Boot the firmware setup, switch Secure Boot to **Custom/Setup mode**
   (or clear keys to enter setup mode).
2. Enroll `EFI/voidling/keys/voidling-sb.cer` into **db** ("Authorized
   signatures" / "enroll from file"). On firmware that only accepts `.auth`,
   use `voidling-sb.auth`. KeyTool users can use the `.esl`.
3. Optional: also enroll it as **KEK** and **PK** to own the platform fully
   (then only Voidling-signed loaders boot). Leaving the vendor PK in place
   and adding only to db is the least disruptive option.
4. Enable Secure Boot and boot the ISO. The kernel prints
   `Secure boot enabled`.

Removing the key from db (or restoring factory keys) reverts the machine.

## Testing in QEMU

```bash
sudo bash tooling/image/test-secureboot-iso.sh            # build + verify + boot
sudo bash tooling/image/test-secureboot-iso.sh --negative # also prove the unsigned ISO is refused
```

The test writes `out/ovmf-vars-voidling-sb.fd` with the certificate as
PK/KEK/db and `SecureBootEnable=ON` (via `virt-fw-vars` from the
`virt-firmware` pip package, installed under `out/hosttools/pylib`), then boots
with `tooling/image/boot-qemu.sh --secure-boot --ovmf-vars …` (SMM OVMF build,
`q35,smm=on`). Success marker: `SECURE_BOOT_OK`.

## Scope and limits

- **Live ISO only.** Installed systems boot the OSTree-committed kernel and
  the GRUB written by `voidling-grub-esp.sh`; those are not signed yet. To
  extend: sign the ESP GRUB at install time with the same key (the private
  key must then be available on the installing host, never on the ISO), and
  either sign kernels at compose time or move to a shim + MOK flow.
- No Microsoft chain: a machine with factory keys only will refuse the medium
  until the Voidling certificate is enrolled. This is intentional.
- `dbx` revocations are the owner's responsibility (no SBAT enforcement
  without shim).
