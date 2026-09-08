# Sourcing

**Sourcing** takes Void-compatible build inputs (a `void-packages` template, plus
its sources and patches) and produces a **user-selectable artifact**, without
mutating the immutable host.

Upstream tool name: **`xbps-src`** (this project also says “xbps-source”).
See [docs/25-sourcing.md](../../docs/25-sourcing.md).

## Invariants

- The host OS is immutable. Sourcing never runs `xbps-install` / `xbps-remove`
  against the booted system root.
- Default payload for the distro remains **unchanged official Void `.xbps`**.
- Builds run in a **container** (`RUNTIME=podman|docker`) or a dedicated
  build environment (`--host`, e.g. Distrobox / CI). Not the product host root.

## Outputs

| `--output` | Result |
|---|---|
| `generation` | Extra PKGS list under `out/sourcing/generation/` for the next composed OS tree |
| `oci` | `buildah` / `podman build` sketch under `out/sourcing/oci/` |
| `flatpak` | `flatpak-builder` manifest sketch under `out/sourcing/flatpak/` |

Activation of a **generation** is atomic (reboot) with rollback. This tree
writes the include list; OSTree / boot / snapshots stay with their owners.

`compose-rootfs.sh` is wired: it appends `out/sourcing/generation/extra-pkgs`
to `PKGS` unless `SOURCING_EXTRAS=0`, and adds `-R` for
`out/cache/void-packages/hostdir/binpkgs` (override: `SOURCING_BINPKGS`)
**before** official Void repos when that directory exists. Same-name sourced
`.xbps` therefore replace official packages. Official Void binaries remain the
default payload; sourced packages are opt-in extras. Compose installs into the
output rootfs only — never the booted `/`.

## Dry-run vs apply

**Default is dry-run.** `--dry-run` (or no flag) prints the plan to stdout and
does not clone, build, or write artifacts.

**`--apply`** is required for clone / `xbps-src` / export. Do not run it unless
you intend to fetch [void-packages](https://github.com/void-linux/void-packages)
and compile.

Export sketches without building:

```bash
VOIDLING_SKIP_XBPS_SRC=1 bash tooling/sourcing/source-package.sh \
  --host --apply --output generation -- hello
```

## void-packages location

| What | Where |
|---|---|
| Clone (not created by dry-run) | `out/cache/void-packages` |
| Override | `VOID_PACKAGES_DIR` |
| Remote | `VOID_PACKAGES_URL` (default `https://github.com/void-linux/void-packages.git`) |
| Built `.xbps` | `out/cache/void-packages/hostdir/binpkgs` |

This folder is a **cache**. The huge upstream repo is **not** cloned by the
default dry-run path.

## CLI

From the repo root:

```bash
bash tooling/sourcing/source-package.sh --help

bash tooling/sourcing/source-package.sh --output generation -- hello
bash tooling/sourcing/source-package.sh --output oci -- hello
bash tooling/sourcing/source-package.sh --output flatpak -- hello

# Real build (container; clones void-packages; can take hours)
RUNTIME=podman bash tooling/sourcing/source-package.sh \
  --apply --output generation -- hello
```

`--output` and the template / package name are required (except `--help`).

## Container

Default image: `voidling-sourcing:local`, built from
[`Containerfile`](Containerfile) in this directory (so this tree does not edit
`tooling/container/`).

```bash
podman build -t voidling-sourcing:local \
  -f tooling/sourcing/Containerfile tooling/sourcing
```

To reuse the compose builder as the base (if it already exists):

```bash
podman build --build-arg BASE=voidling-builder:local \
  -t voidling-sourcing:local \
  -f tooling/sourcing/Containerfile tooling/sourcing
```

`--apply` without `--host` builds the image if needed and re-executes this
script inside the container (`--privileged`, repo bind-mounted at `/work`).
`xbps-src` uses a chroot/unshare masterdir; privilege is required for that,
not for mutating the host.

## Snapshot hook

Before compose / OSTree commit / activate of a **generation** that includes
sourcing output, the snapshots tool must take a snapshot of type
**`pre-sourcing-into-generation`**. This tree documents the hook only; it does
not implement snapshots.

Details: [INTEGRATION.md](INTEGRATION.md).
