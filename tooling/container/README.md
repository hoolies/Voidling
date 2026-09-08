# Container tooling

This folder holds **two different images**. Do not collapse them.

| Role | Tag | Definition | Purpose |
|------|-----|------------|---------|
| **Builder** | `voidling-builder:local` | `Dockerfile` + `run-compose-and-commit.sh` | CI / build-machine runner: xbps + ostree; mounts the repo and composes+commits a rootfs |
| **Product** | `voidling-minimal:local` (default), `voidling-plasma:local` | `product/Containerfile.*` + `build-product-image.sh` | Runtime/base image users `FROM` or attach with Distrobox |

The builder produces host OS trees (compose → OSTree). The product image is a **mutable container userland** so you can install packages without touching the immutable host (where xbps is read-only). runit is PID 1 on the *host*, not the default PID 1 of the product image (`CMD` is `/bin/sh`).

## Apps priority (Flatpak first)

Voidling installs apps in this order. Distrobox is **#3**, not the default:

1. **Flatpak** (Flathub) — preferred for desktop apps
2. **Sourcing** — `xbps-src` → next generation, OCI, or Flatpak
3. **Distrobox** — this product image; a full mutable Void userland
4. **AppImage**

Use Distrobox when you need a Void toolchain or `xbps-install` inside a container. Prefer Flatpak, then Sourcing, first.

## Notes

- In this environment, Podman appears to be functional but prints a **Cursor AppImage**-looking program name in `--help/--version` output. The subcommands and behavior are still Podman-like. `build-product-image.sh` probes `info` and falls back to Docker if Podman is on `PATH` but not usable.

---

## Product image (Distrobox / `FROM` base)

Default variant is **minimal**, matching the compose preset:

- Official unchanged Void `.xbps`
- `base-container` + `ca-certificates`
- `/bin/sh` is **dash** (no bash in the image)
- Ignore `glibc-locales`, `nvi`, `which` (`product/xbps.d/10-voidling-ignore.conf`)

The build context is `product/` only (`xbps.d` snippets). It does **not** import `out/rootfs-*`. Those trees are for OSTree / the host.

Plasma is an optional second target: `FROM voidling-minimal:local` plus the extra packages from `tooling/compose/compose-plasma-rootfs.sh`. It is **large**. The plasma overlay (Zen Browser, skel, mimeapps) is **not** applied — that is a host-desktop concern.

### Build

From the repo root (Podman preferred, Docker fallback):

```bash
bash tooling/container/build-product-image.sh
```

That tags `voidling-minimal:local`.

```bash
# Explicit variant / runtime / tag
bash tooling/container/build-product-image.sh --variant=minimal
bash tooling/container/build-product-image.sh --variant=plasma
RUNTIME=podman bash tooling/container/build-product-image.sh
RUNTIME=docker bash tooling/container/build-product-image.sh --tag=voidling-minimal:local
```

`VARIANT=plasma` builds `voidling-plasma:local` and builds `voidling-minimal:local` first if that FROM image is missing.

Do **not** use `run-compose-and-commit.sh` to build the product image. That script is the builder pipeline only.

### Distrobox (mutable userland, immutable host)

Build the **minimal** product image, then create a container. Distrobox may install helpers (bash, sudo, …) **inside the container**. That is expected: the container is mutable; the host is not.

```bash
bash tooling/container/build-product-image.sh
distrobox create --name voidling --image voidling-minimal:local --pull never
distrobox enter voidling
# xbps-install works here; it does not mutate the host
```

`--pull never` / assemble `pull=false` if your Distrobox would otherwise try to pull `:local` from a registry.

Assemble file: `product/examples/distrobox.ini`

```bash
distrobox assemble create --file tooling/container/product/examples/distrobox.ini
```

Do not pass Distrobox `init=true` unless you intentionally want the guest to start runit. Default (`init=false`) is correct: runit stays the host PID 1.

### `FROM voidling-minimal:local`

After the product image exists locally:

```dockerfile
FROM voidling-minimal:local

RUN XBPS_NONINTERACTIVE=1 xbps-install -Sy git
```

Worked example: `product/examples/Containerfile.from-minimal`

```bash
podman build -t myapp:local -f tooling/container/product/examples/Containerfile.from-minimal .
```

There is no published registry tag yet; `:local` is a local-only name.

---

## Builder runner (compose + OSTree commit)

From repo root:

```bash
bash tooling/container/run-compose-and-commit.sh
```

You can force a runtime:

```bash
RUNTIME=podman bash tooling/container/run-compose-and-commit.sh
RUNTIME=docker bash tooling/container/run-compose-and-commit.sh
```

This will:

1. Build `voidling-builder:local` from `tooling/container/Dockerfile`
2. Run `tooling/compose/compose-minimal-rootfs.sh`
3. Run `VARIANT=minimal tooling/ostree/commit-rootfs.sh`
