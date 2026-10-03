# Voidling — project notes (index)

Use **`@Voidling/docs/`** in Cursor when you want this context without re-pasting upstream docs.

| File | Contents |
|------|----------|
| [00-context-and-goals.md](00-context-and-goals.md) | Aim, scope, architectural reality (Void xbps vs Fedora ostree) |
| [10-immutable-os-model.md](10-immutable-os-model.md) | rpm-ostree / OSTree semantics (immutable base, atomic updates, layering) |
| [20-void-linux.md](20-void-linux.md) | Void: xbps, xbps-src, runit, musl/glibc — links only |
| [25-sourcing.md](25-sourcing.md) | “Sourcing”: xbps-source builds + export to next generation / OCI / Flatpak |
| [26-fenestration.md](26-fenestration.md) | “Fenestration”: optional Windows compatibility/gaming stack (Bazzite-like) |
| [27-filesystems-and-snapshots.md](27-filesystems-and-snapshots.md) | ZFS/Btrfs choice + automatic snapshot/retention policy |
| [27-filesystems-and-snapshots-prototype.md](27-filesystems-and-snapshots-prototype.md) | Snapshot CLI notes (policy is in the file above) |
| [30-upstream-reading-map.md](30-upstream-reading-map.md) | Authoritative URLs and reading order |
| [40-ai-and-token-workflow.md](40-ai-and-token-workflow.md) | Clones vs tokens, what to attach in chats |
| [50-mvp.md](50-mvp.md) | MVP definition (what exists today) |
| [55-installer.md](55-installer.md) | Directory vs disk installer; what a real disk install will do |
| [60-build-and-release.md](60-build-and-release.md) | Build order: keys → compose → commit → ISO/qcow2 → smokes → housekeeping; credential/root policy table |

These files are **distilled** from early planning chats; they are not a full mirror of Fedora or Void documentation.
