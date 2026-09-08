# Upstream reading map

Read **high-level docs first**, then **one end-to-end compose/update pipeline**, then deep dives only where your design touches.

## Order suggested for “Atomic / Bazzite-side” understanding

1. **rpm-ostree** (hybrid image + RPM): https://coreos.github.io/rpm-ostree/
2. **libostree / OSTree** (trees, deployments, hardlink checkout model): https://ostreedev.github.io/ostree/
3. **Fedora Silverblue** (desktop Atomic variant, UX docs): https://silverblue.fedoraproject.org/
4. **Fedora Docs — Silverblue** (handbook-style): https://docs.fedoraproject.org/en-US/fedora-silverblue/  
   - **Note:** That documentation host may use **Anubis** (anti-scraper); automated fetches can fail. **Use a normal browser** for full pages.
5. **Historical “Project Atomic”** context and talks: https://www.projectatomic.io/ (legacy but useful terminology)

## Bazzite / Universal Blue

Use their official repos and docs for **how a derivative composes images**, defaults, and installer integration. Treat as **reference for product shape**, not as the same package format as Void.

## Void

- https://voidlinux.org/
- Handbook and man pages linked from the site.

## When researching “bootable containers”

If you align with Fedora’s newer direction: **bootc** / **bootable containers** (see rpm-ostree site for pointers). Your Void-based system might still use a **different** delivery format; this is optional reading unless you adopt that path.
