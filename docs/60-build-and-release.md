# Build and release (what to run, in order)

One page for producing the shipped artifacts from a clean checkout. All
paths are relative to the repo root; everything lands under `out/`.

## 0. Host prerequisites

- **Void Linux host** (glibc x86_64). CI uses the same toolchain via
  `ghcr.io/void-linux/void-glibc-full` — not Ubuntu.
- Void-style host tools: `xbps-install`, `ostree`, `dracut` (or the one in
  the tree), `grub-mkrescue`/`xorriso`, `mksquashfs`, `qemu-system-x86_64`,
  OVMF. Secure Boot additionally needs `sbsign` and `cert-to-efi-sig-list`;
  `tooling/boot/ensure-secureboot-tools.sh` installs them unprivileged
  under `out/hosttools` if the host lacks them.
- TPM2 QEMU smoke: `swtpm`, `swtpm_setup`, host `clevis`, and a
  `WITH_TPM2=1` compose.
- `shellcheck`, `shfmt` for the lint gate.
- Compose and anything that loop-mounts or chroots runs as root, outside
  the Cursor sandbox.

## 1. Lint and unit tests (no root)

```sh
bash tooling/ci.sh            # shellcheck + shfmt + unit tests
bash tooling/ci.sh --fix      # shfmt -w
# or, with just(1):
just ci
```

The GitHub workflow `.github/workflows/ci.yml` runs the same script inside
a Void container (includes `tooling/ostree/test-deploy-sealed.sh`). See the
root `Justfile` for compose/iso/smoke recipes.

## 2. Keys (once per build host; never committed)

```sh
bash tooling/ostree/ensure-signing-keys.sh      # out/ostree-keys/ed25519.{secret,public}
bash tooling/boot/ensure-secureboot-keys.sh     # out/secureboot-keys/voidling-sb.* + voidling-grub.gpg
```

### Key backup checklist

| Secret | Path | If lost |
|--------|------|---------|
| OSTree ed25519 secret | `out/ostree-keys/ed25519.secret` | New key + rebuild every tree that ships the old pubkey |
| Secure Boot PE key | `out/secureboot-keys/voidling-sb.key` | New cert; re-enroll firmware db; resign ISOs + ESP loaders |
| GRUB GPG home | `out/secureboot-keys/gnupg/` | New GPG key; resign ISO kernel/initrd/grub.cfg |

Back these up offline with the same care as other release secrets. Private
keys never enter git and never ship on the live ISO.

The OSTree public key is copied into every composed tree at
`/usr/share/ostree/trusted.ed25519.d/voidling.ed25519` by
`apply-product-clis.sh`, so installed systems verify upgrades with it.

## 3. Compose and commit (release)

```sh
# Version: git tag preferred (v0.1.0 → VERSION=0.1.0)
git describe --tags --exact-match 2>/dev/null   # or pick VERSION=…

# Minimal (also the live installer root). Shipped ISOs are Btrfs-only:
sudo env WITH_ZFS=0 BOOTABLE=1 SECURE_BOOT=1 \
  bash tooling/compose/compose-minimal-rootfs.sh
sudo env VARIANT=minimal VERSION=0.1.0 VOIDLING_RELEASE=1 OSTREE_SIGN=1 \
  bash tooling/ostree/commit-rootfs.sh

# Plasma
sudo env WITH_ZFS=0 BOOTABLE=1 SECURE_BOOT=1 \
  bash tooling/compose/compose-plasma-rootfs.sh
sudo env VARIANT=plasma VERSION=0.1.0 VOIDLING_RELEASE=1 OSTREE_SIGN=1 \
  bash tooling/ostree/commit-rootfs.sh
```

**Release rules:**

- `VOIDLING_RELEASE=1` (or `OSTREE_SIGN=1`) — signed commits only; no
  unsigned fallback if signing fails.
- `SECURE_BOOT=1` during compose Authenticode-signs kernels in the tree.
- Do **not** set `VOIDLING_OSTREE_RELAX_SPACE=1` on release hosts (that
  disables ostree’s free-space guard). Lab/prototype hosts may set it, or
  `OSTREE_MIN_FREE_SPACE_PERCENT=0`.
- Never set `VOIDLING_KEEP_LAB_CREDENTIALS=1` on shipped installed images.

Knobs: `WITH_ZFS=1` adds ZFS (DKMS) so the installer's `--filesystem=auto`
picks ZFS; `WITH_TPM2=1` adds clevis for `--luks-tpm2`
(`tooling/boot/LUKS-TPM2.md`). Day-to-day prototype commits may use
`OSTREE_SIGN=auto` (default).

## 4. Live initrd and ISO

```sh
sudo bash tooling/image/install-live-dracut.sh --rootfs out/rootfs-x86_64-glibc-minimal
sudo bash tooling/image/build-iso.sh --variant=minimal
sudo bash tooling/image/build-iso.sh --variant=minimal --secure-boot   # signed GRUB/kernel
sudo bash tooling/image/build-iso.sh --variant=plasma
```

**Plasma / plasma-fenestration ISOs** boot the **minimal** live rootfs and
carry `ostree-repo/` for install. They do not pack Plasma as the squashfs
unless you pass `--rootfs`. Squashfs packing stages a copy under `out/tmp`
so the compose tree is never mutated.

`build-iso.sh` prunes a single-ref archive repo (`out/ostree-repo-$VARIANT`)
into the ISO. `SQUASHFS_COMP=zstd` trades a larger image for faster boot.
Secure Boot: `tooling/boot/SECURE-BOOT.md` (live ISO + installed ESP when
`SECURE_BOOT=1` on the installing host).

## 5. QEMU images and smokes (root)

```sh
sudo bash tooling/image/build-ostree-qcow2.sh --filesystem=btrfs
sudo env SECURE_BOOT=1 bash tooling/image/build-ostree-qcow2.sh --filesystem=btrfs   # signed ESP
sudo bash tooling/image/smoke-all.sh                 # upgrade, LUKS, TPM2, live, plasma, login, SB
sudo bash tooling/image/test-secureboot-iso.sh
sudo bash tooling/image/test-luks-tpm2-boot.sh       # needs swtpm + WITH_TPM2=1 tree
```

## 6. Release publish layout

Suggested `out/release/$VERSION/` contents:

| Artifact | Notes |
|----------|--------|
| `voidling-x86_64-uefi-minimal.iso` | Live + install (unsigned or `--secure-boot`) |
| `voidling-x86_64-uefi-plasma.iso` | Minimal live + plasma OSTree on disc |
| `voidling-x86_64-uefi-plasma-fenestration.iso` | Optional; same live model as plasma |
| `SHA256SUMS` | `sha256sum` of every shipped file |
| `SHA256SUMS.sig` | Detached signature (OSTree or GPG release key) |
| `voidling.ed25519` | OSTree public key (also inside the tree) |
| `voidling-sb.cer` | Secure Boot enrollment cert (public) |

```sh
bash tooling/image/publish-release.sh --version=0.1.0
# → out/release/0.1.0/{isos,qcow2,SHA256SUMS,SHA256SUMS.sig,voidling.ed25519,…}
```

Optional offline Fenestration Flatpak cache (packed onto the ISO when present):

```sh
bash tooling/image/prepare-flatpak-cache.sh   # → out/flatpak-cache/*.flatpak
```

Shipped product ISOs keep `WITH_TPM2=0`; TPM2 LUKS bind needs a
`WITH_TPM2=1` compose. Live media includes `dialog` for the guided installer.

Tag the release when artifacts match:

```sh
git tag -a "v${VERSION}" -m "Voidling ${VERSION}"
```

## 7. Housekeeping

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
