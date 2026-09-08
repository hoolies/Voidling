# Plasma overlay

Defaults applied after composing the `plasma` rootfs (the full desktop experience):

- `etc/skel/` — Bourne_Again `git_config/.config` (zsh, vim, tmux, Alacritty, Helix, yazi, conky, espanso, fuzzel, glow, clipse config, functions, Backgrounds). `hoolies` function prefixes are renamed to `voidling`. **Not** copied: XFCE, qtile, git metadata, clipse history.
- Same files seeded into `/root` for the prototype image
- Default login shell: `zsh` (`/etc/default/useradd`, root in `/etc/passwd`); `bash` remains installed
- **Default browser:** Zen Browser (official linux tarball → `/usr/lib/zen-browser`, `zen.desktop`)
- **Default file manager:** Dolphin (`org.kde.dolphin.desktop`) via `etc/xdg/mimeapps.list`
- **Default terminal:** Alacritty via `etc/xdg/kdeglobals`
- **Look:** Tokyo Night Moon for Plasma (generated for KDE; not imported from XFCE). Color scheme `usr/share/color-schemes/TokyoNightMoon.colors` matches Alacritty `tokyonight_moon.toml`. Wallpaper is the existing skel `Backgrounds/Black-void.png` (look-and-feel `org.voidling.tokyonightmoon.desktop`).
- Enabled runit services when present: `dbus`, `elogind`, `NetworkManager`, `sddm`, `bluetoothd`

A new user gets the theme from skel + system XDG:

1. `useradd` copies `/etc/skel` (Bourne_Again tools **and** `Backgrounds/`, plus `kdeglobals` / `kwinrc` / `kscreenlockerrc` seeded by `apply-plasma-overlay.sh`).
2. Plasma also reads `/etc/xdg/kdeglobals` (`ColorScheme=TokyoNightMoon`, Alacritty/Dolphin/Zen defaults kept) and `/usr/share/color-schemes/TokyoNightMoon.colors`.
3. First session applies look-and-feel `org.voidling.tokyonightmoon.desktop`, which points the desktop/lock wallpaper at `$HOME/.config/Backgrounds/Black-void.png`.

Theme files live under `etc/xdg/` and `usr/share/` (not Bourne_Again `git_config`), so `sync-plasma-skel.sh` can refresh tools without dropping the Plasma look. Apply re-seeds `kdeglobals` into skel/`root` after the skel copy.

Refresh skel from the live Bourne_Again tree:

```bash
bash tooling/compose/sync-plasma-skel.sh
```

Zen tarball is cached under `out/cache/`; override with `ZEN_TARBALL_URL` / `ZEN_CACHE_DIR`.
