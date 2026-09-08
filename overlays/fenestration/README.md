# Fenestration overlay

Optional Windows compatibility **without Steam** (Wine/Lutris in the image;
Bottles/Heroic as Flatpaks).

## Enablement

Next immutable generation only. No live `xbps-install` on the booted host.

Detection: `/etc/voidling/fenestration` (`steam=0`).

```bash
bash tooling/compose/compose-fenestration-rootfs.sh
VARIANT=plasma-fenestration bash tooling/ostree/commit-rootfs.sh
```

Reuse Plasma: `SKIP_PLASMA_COMPOSE=1`. Overlay only: also `SKIP_COPY=1`.

## Image extras (`DEFAULT_PKGS`)

Verified Void `.xbps` names (`xbps-query` against `current` and
`current/multilib`). Lutris and Gamescope exist on Void and stay in the seed.

| Package | Repo | Role |
|---------|------|------|
| `wine` | current | Windows compatibility |
| `winetricks` | current | Wine redistributable helper |
| `lutris` | current | Game/library manager |
| `gamescope` | current | Nested compositor |
| `gamemode` | current | On-demand performance |
| `MangoHud` | current | FPS/HUD overlay (capital M/H) |
| `vulkan-loader` | current | Vulkan ICD loader |
| `void-repo-multilib` | current | Multilib repo drop-in |
| `void-repo-multilib-nonfree` | current | Multilib/nonfree drop-in |
| `mesa-dri-32bit` | multilib | 32-bit Mesa DRI |
| `vulkan-loader-32bit` | multilib | 32-bit Vulkan loader |
| `libgcc-32bit` | multilib | 32-bit libgcc |
| `libstdc++-32bit` | multilib | 32-bit libstdc++ |
| `libdrm-32bit` | multilib | 32-bit libdrm |
| `libglvnd-32bit` | multilib | 32-bit GLVND |

**Not in the seed:** Steam, `steam-udev-rules`, GPU-specific
`mesa-vulkan-*-32bit`, `wine-gecko`, `wine-mono`. Override with `PKGS` if
needed.

## Flatpak (Flathub)

Install after boot from `usr/share/voidling/fenestration-flatpaks.txt`. Not
`.xbps`.

| Flatpak ID | App |
|------------|-----|
| `com.usebottles.bottles` | Bottles |
| `com.heroicgameslauncher.hgl` | Heroic |
| `net.davidotek.pupgui2` | ProtonUp-Qt |
| `org.winehq.Wine` | optional extra Wine build |

## Overlay files

- `etc/voidling/fenestration` — marker
- `usr/share/applications/wine-program-loader.desktop`
- `etc/xdg/mimeapps.list` — `.exe` / MSI → Wine (merged)
- `usr/share/voidling/fenestration-flatpaks.txt`

Policy lock: `docs/26-fenestration.md`.
