# Immutable OS model (Fedora Atomic / rpm-ostree family)

This section describes the **Bazzite-side inspiration**: how **rpm-ostree** and **OSTree** achieve an “immutable” desktop/server OS. Your Void-based design may use different tools; keep the **semantics**, not necessarily the **Fedora stack**.

## Mental model

- The **running core OS** (`/usr` and related) is a **checked-out, versioned tree**, not a live mutable bag of packages.
- **Updates** prepare a **new tree**; you **reboot into** it (atomic switch).
- **Rollback** means booting a **previous deployment** that is still retained.

## What “immutable” usually means here

1. **Read-only base at runtime** — core system paths are not casually writable; you do not `dnf install` into the live root.
2. **Atomic updates** — no half-applied system state; either you boot the new version or you roll back.
3. **Writable islands** — typically `/etc` (config, with merge rules), `/var` (state), `/home` (user data). The OS is “protected,” not a sealed box.

## Mechanisms (stack, not a single switch)

- **Read-only mount** of the composed `/usr` (and friends).
- **OSTree**: content-addressed objects, commits, deployments; checkouts use **hardlinks** — checked-out files are expected to be **immutable** to avoid corruption.
- **Transactional upgrade path** — new deployment prepared offline from the running system’s perspective.
- **Separation of concerns** — system vs config vs state vs applications (Flatpak, containers) reduces breakage from app churn.

## Extensions (how users add software without “breaking” the base)

1. **Package layering** (rpm-ostree): adds RPMs by composing a **new derived filesystem**; reboot to apply; base remains conceptually intact.
2. **Flatpak** (common for apps): sandboxed, independent of base.
3. **Containers** (Podman, Distrobox): full mutable dev/user environments without mutating the host root.

## Escape hatches (immutability is default, not absolute)

Overrides, unlocks, and manual root edits exist but **step outside** the supported model and can conflict with updates.

## Upstream emphasis (2024+)

rpm-ostree upstream notes **increased focus on bootc, dnf5, and bootable containers** for new major features; rpm-ostree remains widely deployed. Factor that into long-term tooling choices if you mirror Fedora’s direction for your *own* compose pipeline.
