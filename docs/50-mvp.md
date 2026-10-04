# Minimum Viable Product (MVP)

This MVP is the smallest artifact set that proves Voidling’s core promise:

- consume **unchanged** Void Linux `.xbps` binaries
- compose a filesystem tree
- commit it as an **OSTree-style** versioned root

## What exists today

| Variant | Compose preset | Rootfs | OSTree ref |
|---------|----------------|--------|------------|
| `minimal` | `tooling/compose/compose-minimal-rootfs.sh` | `out/rootfs-x86_64-glibc-minimal/` | `voidling/x86_64/glibc/minimal` |
| `plasma` | `tooling/compose/compose-plasma-rootfs.sh` | `out/rootfs-x86_64-glibc-plasma/` | `voidling/x86_64/glibc/plasma` |
| `plasma-fenestration` | `tooling/compose/compose-fenestration-rootfs.sh` | `out/rootfs-x86_64-glibc-plasma-fenestration/` | `voidling/x86_64/glibc/plasma-fenestration` |

**Minimal:** no DE/WM. Container seed vs `BOOTABLE=1` (kernel, GRUB, dracut, ostree, e2fsprogs, iproute2). Dash `/bin/sh`.

**Plasma:** full KDE + Bourne_Again skel + Tokyo Night Moon Plasma look + Flathub + Alacritty/Zen/Dolphin. `BOOTABLE=1` adds kernel, GRUB, dracut, ostree, e2fsprogs, iproute2. `WITH_ZFS=1` (compose default) adds ZFS (DKMS); the **shipped ISOs/qcow2 are `WITH_ZFS=0`** (Btrfs-only), and the installer's `--filesystem=auto` follows whatever the medium has. `WITH_TPM2=1` adds clevis for TPM2 LUKS auto-unlock.

**Fenestration:** no Steam. Void packages (Wine, Lutris, Gamescope, …) verified present. Bottles/Heroic are Flatpak.

**Seal:** `/usr/etc`, `voidling-immutable` mounts, `voidling-zram` (zram swap, zswap off), ostree dracut module on `BOOTABLE=1`.

## Proven on this host

- Minimal UEFI qcow2 composed, built, and booted in QEMU (GRUB → kernel → ext4 → runit).
- Minimal live ISO composed, packed, and booted in QEMU (GRUB → dmsquash-live → overlayfs → runit login on ttyS0). Artifact: `out/voidling-x86_64-uefi-minimal.iso`.
- Plasma live ISO packed and booted in QEMU (same live path; ZFS userspace present; SDDM starts). Artifact: `out/voidling-x86_64-uefi-plasma.iso`. ISO 9660 level 3 for the >4 GiB squashfs. Live squashfs ships `voidling-installer` / `install-voidling`.
- Product container `voidling-minimal:local` built with Podman (~177MB).
- Sealed OSTree dummy deploy; Fenestration package names queried on Void.
- **OSTree Btrfs qcow2 (minimal):** `build-ostree-qcow2.sh --filesystem=btrfs` → GRUB ESP chain → `/@/boot/grub.cfg` → kernel/initrd → `ostree-prepare-root` → runit stage 2 with `voidling-zram` (`/dev/zram0` swap), zswap blacklisted. Artifact: `out/voidling-x86_64-uefi-ostree-btrfs.qcow2`.
- **OSTree Btrfs qcow2 (plasma):** fresh `WITH_ZFS=0 BOOTABLE=1` compose → OSTree Btrfs qcow2 (`-s 20G`); reaches runit stage 2 and SDDM. Artifact: `out/voidling-x86_64-uefi-ostree-btrfs-plasma.qcow2`.
- **OSTree Btrfs + LUKS:** `build-ostree-qcow2.sh --luks-passphrase-file=…` → LUKS2 on root, `cryptomount` in ESP GRUB, `rd.luks.uuid` karg. Smoke: `tooling/image/test-luks-ostree-boot.sh`. Artifact: `out/voidling-x86_64-uefi-ostree-btrfs-luks.qcow2`.
- **Guest upgrade / rollback / `@var` restore:** `tooling/boot/test-guest-upgrade-rollback.sh` (mounted qcow2 sysroot).
- **Second-disk install smoke (loop):** `tooling/installer/test-second-disk-install.sh`.
- **Live ISO → second disk (QEMU):** `tooling/image/test-live-second-disk-qemu.sh` (minimal ISO packs pruned `ostree-repo-$VARIANT/` + `btrfs-progs`; virtio target; Btrfs). `boot-qemu.sh --iso=… --disk=…`.
- **Smoke suite:** `tooling/image/smoke-all.sh` (upgrade, LUKS unlock→runit, live install, plasma boot, serial login).
- **Lab login:** Default `voidling` / `voidling`. Live ISO: root has **no password** (console only); change the user's with `voidling-set-credentials --change-password`. Installed systems write `require-credential-change` so the first voidling login replaces the lab account and deletes `voidling` (unless `VOIDLING_KEEP_LAB_CREDENTIALS=1` for CI/qcow2).
- **Root access policy (installed):** `install-voidling --root-access=locked|password|none` (default `locked`). `none` keeps the replacement user out of wheel: no root path. Recorded at `/etc/voidling/root-access`; unit tests `tooling/firstboot/test-set-credentials.sh`, `test-configure-system.sh`.
- **Filesystem default:** installer `--filesystem=auto` → ZFS when `zpool`+`zfs` exist on the medium, else Btrfs. Shipped ISOs are Btrfs.
- **@home fstab:** Disk Btrfs installs mount `subvol=@home` at `/home`.
- **LUKS hardening:** PBKDF2 (GRUB) + argon2id second slot; crypttab in deployment `/etc`; kargs persisted for upgrades.
- **OSTree signing:** `ensure-signing-keys.sh` (base64 ed25519); `commit-rootfs.sh` signs by default when the key exists (`OSTREE_SIGN=auto|1|0`) and verifies the commit. The public key ships in the tree (`/usr/share/ostree/trusted.ed25519.d/voidling.ed25519`); `deploy-sysroot.sh` pulls with `--sign-verify=ed25519=inline:…` and `voidling-upgrade` pins `verification-ed25519-key` on the remote, refusing unverified pulls.
- **Secure Boot (opt-in):** live ISO (`build-iso.sh --secure-boot`), compose kernel signing (`SECURE_BOOT=1`), installed ESP signing when keys are on the installing host. Smoke: `tooling/image/test-secureboot-iso.sh`. Docs: `tooling/boot/SECURE-BOOT.md`.
- **LUKS single prompt (opt-in):** `WITH_TPM2=1` compose + `install-voidling --luks-tpm2` (clevis, PCR 7). QEMU smoke: `tooling/image/test-luks-tpm2-boot.sh` (swtpm). Docs: `tooling/boot/LUKS-TPM2.md`.
- **Live initrd:** zfs driver only when the tree ships it; no dracut `FAILED` on Btrfs-only trees.
- **CI gate:** `tooling/ci.sh` on Void (`ghcr.io/void-linux/void-glibc-full`): shellcheck -x, shfmt, unit tests including sealed deploy.
- **Housekeeping:** `tooling/image/clean-out.sh` (dry run default; `--apply` prunes OSTree history and stale `out/tmp`).
- **zswap:** kargs + blacklist + `setup-zram` forces `/sys/module/zswap/parameters/enabled` to `N` (built-in zswap still logs “loaded using pool”).
- **Product CLIs in tree:** `voidling-upgrade` / `voidling-rollback` / `voidling-snapshot` / `voidling-set-credentials` under `/usr` via `apply-product-clis.sh`.
- **GRUB ↔ Btrfs contract:** `tooling/boot/GRUB-BTRFS.md`.
- **Install media repo:** `tooling/ostree/prepare-install-repo.sh` (single-ref archive); `build-iso.sh` uses `OUT_DIR/tmp` and packs that slim repo by default.

The flat ext4 qcow2 prototype **omits** the OSTree dracut module. The live ISO **omits** it too (squashfs + overlayfs). OSTree deployments **include** it. Do not mix those initramfs configs.

## Pipeline

| Area | Entry | Notes |
|------|--------|--------|
| VM (ext4) | `tooling/image/boot-qemu.sh` | After `build-vm-uefi-qcow2.sh` |
| VM (OSTree) | `build-ostree-qcow2.sh` then `boot-qemu.sh --image …` | Installer runs `grub-install` + ESP chain |
| Live ISO | `install-live-dracut.sh` then `build-iso.sh`; `boot-qemu.sh --iso` | Side file `out/initramfs-*-live.img`; `build-iso.sh` rejects OSTree initrd / missing dmsquash |
| OSTree deploy | `tooling/ostree/deploy-sysroot.sh` | Sealed trees skip `/etc` rewrite |
| Upgrade / rollback | `tooling/boot/voidling-upgrade.sh` / `voidling-rollback.sh` | Snapshot hook + deploy + menu |
| Disk install | `install-voidling.sh --target=disk --i-understand-this-wipes-disks` | Real mkfs when armed. **`--luks-passphrase-file`** formats LUKS2 on disk apply; `--luks-tpm2` seals a TPM2 slot; `--root-access=…` sets the root policy. Live ISO: `sudo voidling-installer` |
| Build order | `docs/60-build-and-release.md` | Keys → compose → commit → ISO/qcow2 → smokes → `clean-out.sh` |
| Snapshots | `voidling-snapshot.sh restore` | `/var` only, not OSTree rollback |
| Sourcing | compose reads `extra-pkgs` | Local binpkgs `-R` first |
| First-boot | `tooling/firstboot/configure-system.sh` | Hostname/user/Flathub; `--swap`/`--luks` plan in dir mode |

## Still not a shipping product

- OSTree ZFS qcow2 is out of scope on this host (no host ZFS userspace by choice).
- Disk swap partitions and a production installer TUI remain future work.
- ARM back-burner.
