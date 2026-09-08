# Sourcing integration

This file is the hook contract for other Voidling trees. **Sourcing does not
edit** OSTree commit, installer, boot, snapshots, fenestration, or
`tooling/container/`. Compose auto-includes generation extras (see below).

## Compose hook (generation)

`--output generation` writes:

| File | Role |
|---|---|
| `out/sourcing/generation/extra-pkgs` | One XBPS name per line (append-safe; comments/`#` and blanks ignored) |
| `out/sourcing/generation/<template>.meta` | template, arch, binpkgs path, snapshot hook name |

Checked-in format example: [`templates/extra-pkgs.example`](templates/extra-pkgs.example).

`compose-rootfs.sh` is wired:

1. When `SOURCING_EXTRAS` is not `0`, it appends names from
   `<OUT_DIR>/sourcing/generation/extra-pkgs` to `PKGS` (comments and blank
   lines ignored). Set `SOURCING_EXTRAS=0` to skip.
2. When `<OUT_DIR>/cache/void-packages/hostdir/binpkgs` exists (override with
   `SOURCING_BINPKGS`), compose adds `-R` for that directory **before** official
   `REPO_CURRENT` / `REPO_CURRENT_NONFREE`. xbps searches `-R` repos in order,
   so a same-name sourced `.xbps` replaces the official package when present.

Official Void `.xbps` remain the **default** payload. Sourced packages are
opt-in extras (or a same-name replacement when the local binpkgs repo is
present and listed first).

Host xbps is read-only: compose installs into the output rootfs (`-r`), never
the booted `/`. Sourcing never mutates the live host.

`IGNOREPKGS` and `VARIANT` are unchanged. Fenestration, installer, and OSTree
stay with their owners.

## Snapshot hook (`pre-sourcing-into-generation`)

Locked type in [docs/27-filesystems-and-snapshots.md](../../docs/27-filesystems-and-snapshots.md).

**When:** immediately **before** applying generation output — i.e. before
compose + OSTree commit + atomic activate of a tree that includes
`out/sourcing/generation/extra-pkgs`.

**Who:** the snapshots / apply-generation orchestrator. Sourcing prints the
type name and writes it into `<template>.meta`. It does **not** create
snapshots.

**Retention (already decided):** last 3 automatic snapshots per type, plus
user-pinned.

## OCI hook

`--output oci` writes `out/sourcing/oci/Containerfile` plus a `binpkgs/`
placeholder. After a real `xbps-src` build, matching
`<template>-*.xbps` are copied into that `binpkgs/` directory.

Sketch commands (also printed by dry-run):

```bash
podman build -t localhost/voidling-sourced-TEMPLATE:local \
  -f out/sourcing/oci/Containerfile out/sourcing/oci
podman save --format oci-archive \
  -o out/sourcing/oci/TEMPLATE.oci.tar \
  localhost/voidling-sourced-TEMPLATE:local
```

`buildah bud` / `buildah push oci-archive:...` is the other sketched path.
`--apply` runs one of those only if `buildah` or `RUNTIME` is present **and**
`VOIDLING_SKIP_XBPS_SRC` is not set.

Template: [`templates/Containerfile.oci`](templates/Containerfile.oci).

## Flatpak hook

`--output flatpak` writes a **manifest + README**, not a guaranteed
`flatpak-builder` success. Mapping a `void-packages` template onto Flatpak
modules is package-specific.

| File | Role |
|---|---|
| `out/sourcing/flatpak/org.voidling.sourced.<template>.yml` | sketch manifest |
| `out/sourcing/flatpak/README.md` | how to run `flatpak-builder` |
| `out/sourcing/flatpak/<template>.meta` | app-id / runtime |

Default runtime: `org.freedesktop.Platform` `24.08` (`FLATPAK_RUNTIME` /
`FLATPAK_RUNTIME_VERSION`). `--apply` invokes `flatpak-builder` only if that
binary exists and `VOIDLING_SKIP_XBPS_SRC` is unset.

Template: [`templates/org.voidling.sourced.yml`](templates/org.voidling.sourced.yml).

## Container vs compose builder

| Image | Owner | Purpose |
|---|---|---|
| `voidling-builder:local` | `tooling/container/` | compose + OSTree commit |
| `voidling-sourcing:local` | `tooling/sourcing/Containerfile` | xbps-src + export |

Sourcing may `FROM voidling-builder:local` via `--build-arg BASE=...` if that
image already exists. It must not take ownership of `tooling/container/`.

Inside the sourcing container, paths are `/work/...` (repo bind-mount).
`void-packages` is always `/work/out/cache/void-packages` in that mode.

`--apply` uses `--privileged` so `xbps-src` can unshare/chroot its masterdir.
That does not authorize host `/usr` mutation.

`--host` is for Distrobox / CI / this same container after re-exec. Do not use
it on the immutable product root.

## Environment (apply path)

| Variable | Default |
|---|---|
| `RUNTIME` | `podman`, else `docker` |
| `IMAGE` | `voidling-sourcing:local` |
| `OUT_DIR` | `<repo>/out` |
| `VOID_PACKAGES_DIR` | `<OUT_DIR>/cache/void-packages` |
| `VOID_PACKAGES_URL` | `https://github.com/void-linux/void-packages.git` |
| `TARGET_ARCH` | `x86_64` |
| `VOIDLING_SKIP_XBPS_SRC` | unset / `0` (set `1` to write sketches only) |

Compose (generation include):

| Variable | Default |
|---|---|
| `SOURCING_EXTRAS` | unset / not `0` (append `extra-pkgs` to `PKGS`) |
| `SOURCING_BINPKGS` | `<OUT_DIR>/cache/void-packages/hostdir/binpkgs` (`-R` only if the directory exists; listed before official repos) |

## What this tree does not do

- Clone `void-packages` on dry-run
- Mutate the live host with `xbps`
- Call the snapshotter
- Own compose `IGNOREPKGS` / `VARIANT`, or `tooling/container/`
- Implement OSTree commit, installer, boot, or fenestration
