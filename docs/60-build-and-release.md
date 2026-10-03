# Build and release (what to run, in order)

One page for producing the shipped artifacts from a clean checkout. All
paths are relative to the repo root; everything lands under `out/`.

## 0. Host prerequisites

- Void-style host tools: `xbps-install`, `ostree`, `dracut` (or the one in
  the tree), `grub-mkrescue`/`xorriso`, `mksquashfs`, `qemu-system-x86_64`,
  OVMF. Secure Boot additionally needs `sbsign` and `cert-to-efi-sig-list`;
  `tooling/boot/ensure-secureboot-tools.sh` installs them unprivileged
  under `out/hosttools` if the host lacks them.
- `shellcheck`, `shfmt` for the lint gate.
- Compose and anything that loop-mounts or chroots runs as root, outside
  the Cursor sandbox.

## 1. Lint and unit tests (no root)

```sh
bash tooling/ci.sh            # shellcheck + shfmt + unit tests
bash tooling/ci.sh --fix      # shfmt -w
```

The GitHub workflow `.github/workflows/ci.yml` runs the same script.

## 2. Keys (once per build host; never committed)

```sh
bash tooling/ostree/ensure-signing-keys.sh      # out/ostree-keys/ed25519.{secret,public}
bash tooling/boot/ensure-secureboot-keys.sh     # out/secureboot-keys/voidling-sb.* + voidling-grub.gpg
```

The OSTree public key is copied into every composed tree at
`/usr/share/ostree/trusted.ed25519.d/voidling.ed25519` by
`apply-product-clis.sh`, so installed systems verify upgrades with it.
Secrets stay in `out/` (git-ignored). Losing the OSTree secret means a
new key and a tree rebuild; back it up where you keep release secrets.

## 3. Compose and commit

```sh
# Minimal (also the live installer root). Shipped ISOs are Btrfs-only:
sudo env WITH_ZFS=0 BOOTABLE=1 bash tooling/compose/compose-minimal-rootfs.sh
sudo env VARIANT=minimal bash tooling/ostree/commit-rootfs.sh

# Plasma
sudo env WITH_ZFS=0 BOOTABLE=1 bash tooling/compose/compose-plasma-rootfs.sh
sudo env VARIANT=plasma bash tooling/ostree/commit-rootfs.sh
```

Knobs: `WITH_ZFS=1` adds ZFS (DKMS) so the installer's `--filesystem=auto`
picks ZFS; `WITH_TPM2=1` adds clevis for `--luks-tpm2`
(`tooling/boot/LUKS-TPM2.md`). `OSTREE_SIGN=auto` (default) signs when the
secret key exists; `OSTREE_SIGN=1` refuses to commit unsigned.

## 4. Live initrd and ISO

```sh
sudo bash tooling/image/install-live-dracut.sh --rootfs out/rootfs-x86_64-glibc-minimal
sudo bash tooling/image/build-iso.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal --secure-boot   # signed GRUB/kernel
sudo bash tooling/image/build-iso.sh --variant=plasma
```

`build-iso.sh` prunes a single-ref archive repo (`out/ostree-repo-$VARIANT`)
into the ISO. `SQUASHFS_COMP=zstd` trades a larger image for faster boot.
The Secure Boot chain and enrollment files are described in
`tooling/boot/SECURE-BOOT.md`.

## 5. QEMU images and smokes (root)

```sh
sudo bash tooling/image/build-ostree-qcow2.sh --filesystem=btrfs
sudo bash tooling/image/smoke-all.sh                 # upgrade, LUKS, live install, plasma, login
sudo bash tooling/image/test-secureboot-iso.sh       # enrolled OVMF, expects "Secure boot enabled"
```

## 6. Housekeeping

```sh
bash tooling/image/clean-out.sh            # dry run: prune plan + stale out/tmp
sudo bash tooling/image/clean-out.sh --apply
```

Keys, rootfs trees and qcow2/ISO artifacts are never deleted by that
script; it prunes OSTree history (keeps current + previous commit per
ref) and removes stale scratch directories.

## Credentials and root access on the result

| Medium | root | `voidling` user |
|--------|------|-----------------|
| Live ISO | no password (autologin-grade, console only) | `voidling`/`voidling`; `voidling-set-credentials --change-password` |
| Installed, `--root-access=locked` (default) | locked | first login forces a replacement admin user (wheel) and deletes `voidling` |
| Installed, `--root-access=password` | shares the new user's password | as above, user in wheel |
| Installed, `--root-access=none` | locked | replacement user **not** in wheel; no root path at all |

`VOIDLING_KEEP_LAB_CREDENTIALS=1` keeps `voidling`/`voidling` for CI
images only.
