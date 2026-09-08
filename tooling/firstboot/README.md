# First-boot / installer extras

Hostname, a wheel/sudo user, locale, NetworkManager, Flatpak (Flathub),
and Distrobox/AppImage policy. Optional swap and LUKS are **documented
flags only** (default off). This folder never runs `xbps-install` on the
host or SYSROOT.

## What the installer should call

Directory mode, after OSTree deploy + bootloader:

```bash
bash -- tooling/firstboot/configure-system.sh
```

`install-voidling.sh` already does that when this script exists (helper
name `firstboot`). Configuration is the shared installer environment
(`SYSROOT`, `VARIANT`, `DRY_RUN`, …) plus optional `VOIDLING_HOSTNAME`,
`VOIDLING_USER`, `SWAP`, and `LUKS`.

`configure-system.sh` then calls, if present:

- `setup-flatpak.sh`
- `apps-policy.sh`

Do not call `xbps-install` from the installer or these scripts.

## Scripts

| Script | Role |
|--------|------|
| `configure-system.sh` | Hostname, user (wheel + sudoers), locale, NetworkManager, storage plan |
| `setup-flatpak.sh` | Ensure Flathub remote; document Fenestration `flatpak install` if the marker is present |
| `apps-policy.sh` | Distrobox / AppImage policy (Flatpak remains first) |

```bash
bash tooling/firstboot/configure-system.sh --sysroot=/path/to/sysroot
bash tooling/firstboot/configure-system.sh --help
```

## Locale

| Tree | LANG | Notes |
|------|------|--------|
| `VARIANT=minimal` or `ignorepkg=glibc-locales` | `C.UTF-8` if the libc ships it, else `C` | `en_US.UTF-8` is not generated. See `etc/voidling/locale-notes.txt` (C/POSIX). |
| Plasma / locales not ignored | `C.UTF-8` (or `--locale=en_US.UTF-8`) | Still no `xbps-reconfigure`. |

## Flatpak

Flathub is already shipped as
`overlays/plasma/usr/share/flatpak/remotes.d/flathub.flatpakrepo`.
`setup-flatpak.sh` leaves that file alone when it exists in the SYSROOT.
Otherwise it writes the same remote under **mutable**
`etc/flatpak/remotes.d/` (does not mutate OSTree `/usr`).

If `/etc/voidling/fenestration` (or `/usr/etc/voidling/fenestration`) is
present, it writes `etc/voidling/fenestration-flatpaks.plan` with
`flatpak install --or-update flathub …` lines for the Fenestration list.
That file is documentation; this script does not run `flatpak install`.

## Distrobox and AppImage

Policy only (`apps-policy.sh` / `etc/voidling/apps-policy`):

1. Flatpak (Flathub)
2. Sourcing
3. Distrobox from the **product container image** (`voidling-minimal:local`)
4. AppImage last, in the user's home

See `tooling/container/README.md`. Distrobox may install helpers inside
the container; that does not change the immutable host.

## Encryption and swap (plan-only)

Default **off**. Directory mode **never** requires LUKS and never creates
swap.

| Flag | Installer | `configure-system.sh` | What happens in dir mode |
|------|-----------|------------------------|--------------------------|
| `--swap` | records `SWAP=1` in `plan.env` | writes `etc/voidling/storage-plan.env` | plan only |
| `--luks` | records `LUKS=1` in `plan.env` | same file | plan only |

Still not implemented (other owners): `cryptsetup`, `mkswap`, `mkfs`,
fstab swap lines, TPM, or a wiping disk installer.

## Dir-mode test (fake sysroot)

```bash
tmp="$(mktemp -d)"
sysroot="$tmp/sysroot"
mkdir -p -- "$sysroot/etc/sv/NetworkManager" \
    "$sysroot/etc/xbps.d" \
    "$sysroot/etc/voidling" \
    "$sysroot/etc/runit/runsvdir/default"
printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' >"$sysroot/etc/passwd"
printf '%s\n' 'root:x:0:' 'wheel:x:4:' >"$sysroot/etc/group"
printf '%s\n' 'ignorepkg=glibc-locales' >"$sysroot/etc/xbps.d/10-voidling-ignore.conf"
printf '%s\n' 'enabled=1' 'variant=plasma-fenestration' >"$sysroot/etc/voidling/fenestration"

bash tooling/firstboot/configure-system.sh \
    --sysroot="$sysroot" \
    --hostname=testhost \
    --user=alice \
    --swap \
    --luks
```

Expect `etc/hostname`, a wheel user, `C` or `C.UTF-8` locale notes,
NetworkManager enabled, Flathub under `etc/flatpak/remotes.d`, a
Fenestration flatpak plan, and `SWAP=1` / `LUKS=1` in
`etc/voidling/storage-plan.env` only.

Contracts: [INTEGRATION.md](INTEGRATION.md).
