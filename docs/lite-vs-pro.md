# Lite vs Pro

Both editions are built from one codebase. The split is **which renderers and tools
ship**, not which UI you get — Lite is a lightweight runtime, not a stripped-down
interface. Video / HTML / Apple Aerials fidelity is identical.

| Capability | Lite | Pro |
|---|:---:|:---:|
| Video wallpapers | ✅ | ✅ |
| HTML / web wallpapers | ✅ | ✅ |
| Apple Aerials | ✅ | ✅ |
| Per-display wallpapers | ✅ | ✅ |
| Playlists · scheduling · bookmarks | ✅ | ✅ |
| Real-time effects · particle overlays | ✅ | ✅ |
| Weather-reactive scenes | ✅ | ✅ |
| Game / full-screen auto-pause | ✅ | ✅ |
| Launch-time update check | ✅ | ✅ |
| **Metal shader procedural wallpapers** | — | ✅ |
| **Wallpaper-Engine scene rendering** | — | ✅ |
| **Local copied project-folder import** | — | ✅ |
| **Steam Workshop URL preview** | — | ✅ |
| **Developer-tools harness** | — | ✅ |

## How the split is implemented

Pro-only sources are gated with `#if !LITE_BUILD`. The Lite scheme
(`LiveWallpaperLite`) sets the `LITE_BUILD` compilation condition, so the Metal scene
renderer, shader pipeline, local-import, Workshop, and dev-tools code are compiled
out of the Lite binary entirely — they aren't merely hidden.

The runtime source of truth for what an edition exposes is
[`ProductCapabilities.swift`](../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## Licensing

- **Lite** is MIT and distributed here on GitHub Releases.
- **Pro** is the full edition. The MIT [`LICENSE`](../LICENSE) covers the entire
  repository, including the Pro-only modules.
