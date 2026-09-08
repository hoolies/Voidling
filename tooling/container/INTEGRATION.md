# Container tooling — integration notes

For other Voidling agents. This folder owns **both** the builder runner and the product image. Keep the two jobs separate.

## Do not replace the builder

| Image | Default tag | Files | Job |
|-------|-------------|-------|-----|
| Builder | `voidling-builder:local` | `Dockerfile`, `run-compose-and-commit.sh` | Mount the repo; compose a rootfs; OSTree-commit it |
| Product | `voidling-minimal:local`, `voidling-plasma:local` | `product/Containerfile.*`, `build-product-image.sh` | Runtime/base for Distrobox and `FROM` |

`run-compose-and-commit.sh` must keep its current default behavior (build the builder image, compose **minimal**, commit **minimal**). Do not retarget it at product Containerfiles.

`build-product-image.sh` accepts `VARIANT=minimal|plasma`, `RUNTIME=podman|docker` (auto if unset; probes `info` and prefers Podman), and tags `voidling-VARIANT:local`.

## Product image vs composed rootfs vs OSTree

- Compose writes `out/rootfs-$ARCH-$LIBC-$VARIANT/` for OSTree (host OS).
- The product image **re-applies the same package policy** from official Void `.xbps` on top of `docker.io/voidlinux/voidlinux`. It does **not** import the composed rootfs (that would ship host-only bits and is a long, disk-heavy path).
- Build context is `tooling/container/product/` with `.dockerignore` / `.containerignore` sending only `xbps.d/`.
- The product image is therefore **policy-aligned**, not a byte-identical export of `out/rootfs-*-minimal`.
- OSTree commit tooling is unchanged and must not be edited from this folder’s work.

## Package-list source of truth

| Variant | Preset | Product Containerfile |
|---------|--------|------------------------|
| `minimal` | `tooling/compose/compose-minimal-rootfs.sh` (`base-container ca-certificates`; ignore `glibc-locales nvi which`) | `product/Containerfile.minimal` + `product/xbps.d/` |
| `plasma` | `tooling/compose/compose-plasma-rootfs.sh` extra pkgs | `product/Containerfile.plasma` (`FROM` minimal + those extras) |

If a compose preset changes packages or ignores, update the matching product Containerfile / `xbps.d` snippet.

**Not applied to product images:** `overlays/plasma` (Zen Browser, skel, mimeapps, SDDM/NM enablement). Those belong to the host Plasma rootfs.

## Sourcing (do not implement here)

Sourcing may later **export OCI images** (see `docs/25-sourcing.md`: next OSTree generation, OCI, or Flatpak). Those artifacts are *derived* outputs. They should typically `FROM voidling-minimal:local` (or a later published equivalent).

This folder does **not** implement xbps-src, a sourcing registry, or Flatpak export. Do not wire sourcing into `build-product-image.sh`.

## Distrobox vs host invariants

- Host: immutable; xbps **read-only**; runit is PID 1.
- Distrobox container from the product image: **mutable**; xbps works; Distrobox may add bash/sudo/etc. inside the container.
- Product `CMD` is `/bin/sh` (dash on minimal). Distrobox replaces the command. Do not start runit as the container default.

## Apps priority

1. **Flatpak** (Flathub)
2. **Sourcing**
3. **Distrobox** (this product image)
4. **AppImage**

The product image is the Distrobox / `FROM` base, not a Flatpak runtime. Distrobox stays #3.

## Out of scope for this folder’s other agents

Do not edit compose scripts, ostree commit, `image/`, installer, overlays, fenestration, or sourcing from container work unless you own those paths.
