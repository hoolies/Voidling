# First-boot integration

Owner of hostname, users, locale, network enablement, Flatpak first-boot,
and Distrobox/AppImage policy. Disk `mkfs` stays with the installer /
snapshots agents. Do not edit `compose-rootfs.sh` from this folder.

## Installer hook

`tooling/installer/install-voidling.sh` should invoke **one** helper,
after snapshots → ostree → boot:

```
bash -- "$VOIDLING_ROOT/tooling/firstboot/configure-system.sh"
```

Missing or non-executable: record and skip (same as other prototype
helpers). Disk mode: record the command; do not execute.

Shared environment (same table as `tooling/installer/INTEGRATION.md`),
plus:

| Variable | Example | Meaning |
|----------|---------|---------|
| `VOIDLING_HOSTNAME` | `voidling` | Hostname written to `etc/hostname` (do not use `HOSTNAME`) |
| `VOIDLING_USER` | `voidling` | Login name (wheel + sudoers) |
| `VOIDLING_UID` | `1000` | uid / primary gid (≥ 1000) |
| `VOIDLING_SHELL` | `/bin/zsh` | Optional; otherwise detect zsh, bash, `/bin/sh` |
| `VOIDLING_PASSWORD_HASH` | `!` | Shadow hash; default locked |
| `VOIDLING_LOCALE` | `en_US.UTF-8` | Only when glibc-locales is **not** ignored |
| `SWAP` | `0` or `1` | Optional swap **plan** (default off) |
| `LUKS` | `0` or `1` | Optional LUKS **plan** (default off) |

`configure-system.sh` may then run `setup-flatpak.sh` and `apps-policy.sh`
with `--sysroot="$SYSROOT"`. The installer does not need a second hook.

## Expected CLI

```
Usage: configure-system.sh [OPTION]... [SYSROOT]
Usage: setup-flatpak.sh [OPTION]... [SYSROOT]
Usage: apps-policy.sh [OPTION]... [SYSROOT]
```

Flags of interest: `--sysroot`, `--hostname`, `--user`, `--swap`,
`--luks`, `--dry-run`, `--help`. Honor `DRY_RUN=1`.

Exit 0 success, 1 runtime failure, 2 usage error.

## Behavior

### `configure-system.sh`

Writes into the mutable `etc` of `SYSROOT` (or the latest
`ostree/deploy/$OSNAME/deploy/*.N/etc` when that layout exists):

- `etc/hostname`
- `etc/passwd`, `etc/group`, `etc/shadow`, `etc/sudoers.d/voidling-wheel`
  (`%wheel ALL=(ALL:ALL) ALL`); home at `$SYSROOT/home/$user`
- `etc/locale.conf` and `etc/voidling/locale-notes.txt`
- `etc/runit/runsvdir/default/NetworkManager` → `/etc/sv/NetworkManager`
  when NetworkManager is present; otherwise skip
- `etc/voidling/storage-plan.env` for `--swap` / `--luks`

Never: `xbps-install`, `xbps-reconfigure`, `cryptsetup`, `mkswap`, `mkfs`.

### Locale

- glibc-locales ignored (`VARIANT=minimal` or `ignorepkg=glibc-locales`):
  `LANG=C.UTF-8` if the tree has that locale dir, else `LANG=C`. Document
  C/POSIX in `locale-notes.txt`. Do not emit `en_US.UTF-8`.
- Otherwise: `C.UTF-8`, or `--locale` / `VOIDLING_LOCALE`.

### `setup-flatpak.sh`

1. If `usr/share/flatpak/remotes.d/flathub.flatpakrepo` exists, keep it.
2. Else copy the Plasma overlay file into **mutable**
   `etc/flatpak/remotes.d/flathub.flatpakrepo` (do not rewrite OSTree `/usr`).
3. If `etc/voidling/fenestration` or `usr/etc/voidling/fenestration` exists,
   write `etc/voidling/fenestration-flatpaks.plan` documenting:

   ```
   flatpak install --or-update flathub com.usebottles.bottles
   flatpak install --or-update flathub com.heroicgameslauncher.hgl
   flatpak install --or-update flathub net.davidotek.pupgui2
   flatpak install --or-update flathub org.winehq.Wine
   ```

   (IDs from `overlays/fenestration/usr/share/voidling/fenestration-flatpaks.txt`
   when present.) Do **not** run `flatpak install`.

### Distrobox / AppImage

`apps-policy.sh` writes `etc/voidling/apps-policy`. Distrobox comes from
`tooling/container/build-product-image.sh` (`voidling-minimal:local`).
AppImage is last. No host xbps.

## Plan-only vs disk-apply flags

`--swap` and `--luks` (installer and `configure-system.sh`):

- Default **off**.
- Directory mode: record `SWAP=` / `LUKS=` in `plan.env` and
  `etc/voidling/storage-plan.env`. Do not create a swap file, partition,
  or LUKS container. Dir mode must succeed with both flags unset.
- Disk apply (`--i-understand-this-wipes-disks` + `--luks-passphrase-file`):
  formats LUKS2 on the root partition, writes `crypttab`, and adds
  `rd.luks.uuid=…` to kernel args. Disk swap partitions are still not created.
- zram swap is the `voidling-zram` service. It does not read `SWAP`.

## What this folder will not do

- Disk partition / `mkfs` / `wipefs` / `zpool create`
- Edit `tooling/compose/compose-rootfs.sh`
- Live `xbps-install` on a running host
- Require LUKS for directory-mode installs
