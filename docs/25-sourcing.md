# Sourcing (xbps-src → artifact, never live xbps)

## Definition

**Sourcing** builds Void-compatible software **off the booted host** and emits a
user-chosen artifact. The running OS is not a package manager sandbox.

Upstream tool: **`xbps-src`** (void-packages). This project also says “xbps-source”.

## Why it exists

On Voidling you cannot `xbps-install` into the live root: `/usr` and the xbps
database/cache are mounted read-only. Sourcing is how you still *build* a Void
package. What you do with the result is a separate choice.

## Where it runs

Always in a **container or dedicated builder** (`voidling-sourcing:local`,
Distrobox, CI). Never in the product host’s `/`.

`--apply` uses `--privileged` only so `xbps-src` can unshare/chroot its
masterdir. That is not permission to edit the host `/usr`.

Default CLI is **dry-run**. `--apply` clones
[void-packages](https://github.com/void-linux/void-packages) into
`out/cache/void-packages` and compiles (can take hours).

## Three outputs (pick one per run)

### 1. `generation` — next immutable OS tree

Use when the thing **must live in `/usr`** of the OS (kernel module, session
helper, Wine-related library you want in Fenestration, a tool every user needs
at boot).

Flow:

1. Snapshot type `pre-sourcing-into-generation` (system `/var` only).
2. `xbps-src` produces `.xbps` under `out/cache/void-packages/hostdir/binpkgs`.
3. `out/sourcing/generation/extra-pkgs` lists the names.
4. Compose splices those names into `PKGS` and `-R`s the local binpkgs
   repo when present (see `tooling/compose/compose-rootfs.sh` and
   `tooling/sourcing/INTEGRATION.md`).
5. OSTree commit + reboot into the new deployment. Rollback is a previous
   deployment, not `xbps-remove`.

Official Void binaries stay the **default** payload. A sourced `.xbps` is an
opt-in extra. Same-name replacement only happens if compose is pointed at the
local binpkgs repo **ahead of** `repo-default`.

Do **not** use generation for a desktop app you could ship as a Flatpak.

### 2. `flatpak` — preferred for apps

Matches **Flatpak first**. Sourcing can sketch a `flatpak-builder` manifest
(`out/sourcing/flatpak/`). You install the result with Flatpak on the running
system (`/var`), which does not remount `/usr`.

Use this for GUI apps, game launchers, and anything that should update without
a host reboot.

### 3. `oci` — containers

A Containerfile plus optional binpkgs, for Podman/Distrobox. The host OS stays
untouched. Use this for services, toolchains, and “I need a mutable userland”.

## What sourcing is not

- Not `xbps-install` on the booted machine.
- Not a substitute for Flathub when the app is already there.
- Not Fenestration (Fenestration is a compose variant). You *may* source an
  extra library into a `plasma-fenestration` generation.

## CLI (prototype)

```bash
bash tooling/sourcing/source-package.sh --help
bash tooling/sourcing/source-package.sh --output generation -- hello
bash tooling/sourcing/source-package.sh --output flatpak -- hello
bash tooling/sourcing/source-package.sh --output oci -- hello

# Real build (container; clones void-packages)
RUNTIME=podman bash tooling/sourcing/source-package.sh \
  --apply --output generation -- hello
```

Details: `tooling/sourcing/README.md`.
