# Fenestration (optional Windows compatibility stack)

## Definition

**Fenestration** is an optional image feature that gives Bazzite-like **Windows
app compatibility** on an immutable Voidling host. It is **not** Steam.

## Locked decisions

- **No Steam** in the image (not default, not optional seed).
- **Scope:** system-wide Windows compatibility:
  - Wine + Winetricks on the immutable image
  - 32-bit graphics/runtime libs for Win32 executables
  - Lutris and Gamescope when packaged in Void
  - GameMode + MangoHud
  - **Bottles, Heroic, ProtonUp-Qt** as **Flatpaks** (Flathub), not `.xbps`
- **Delivery:** next immutable generation only (`plasma-fenestration`). No live
  `xbps-install` on the booted host.

## Why Flatpak for some of it

Proton “magic” on Bazzite is a mix of image packages and user-space launchers.
On Voidling, apps that churn (Bottles, Heroic, Proton version managers) follow
**Flatpak first**. Wine/Vulkan/Gamescope stay in the image so `.exe` files and
Lutris have a host stack without mutating `/usr`.

Recommended Flatpaks (also in
`usr/share/voidling/fenestration-flatpaks.txt`):

| Flatpak ID | App |
|------------|-----|
| `com.usebottles.bottles` | Bottles |
| `com.heroicgameslauncher.hgl` | Heroic |
| `net.davidotek.pupgui2` | ProtonUp-Qt |
| `org.winehq.Wine` | optional extra Wine build |

## Image extras (`DEFAULT_PKGS`)

Verified Void `.xbps` names in
`tooling/compose/compose-fenestration-rootfs.sh`. Lutris and Gamescope exist
on Void (`lutris`, `gamescope`). Nothing from this seed was dropped.

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
`mesa-vulkan-*-32bit`, `wine-gecko`, `wine-mono`.

## Constraints

- Host stays immutable; `xbps` is read-only **via mounts**.
- Compose extras are official Void `.xbps` names only.
