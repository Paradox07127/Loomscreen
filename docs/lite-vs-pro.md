# Lite vs Pro

Both editions are built from one codebase. The split is **which renderers and tools
ship**, not which UI you get — Lite is a lightweight runtime, not a stripped-down
interface. Video / HTML / Apple Aerials fidelity is identical.

| Capability | Lite | Pro |
|---|:---:|:---:|
| Video wallpapers | ✅ | ✅ |
| HTML / web wallpapers | ✅ | ✅ |
| Apple Aerials | ✅ | ✅ |
| Video preload & audio/playlist/schedule/preset features | ✅ | ✅ |
| Weather-reactive scenes | ✅ | ✅ |
| Per-display wallpapers | ✅ | ✅ |
| Bookmarks | ✅ | ✅ |
| Playlists | ✅ | ✅ |
| Schedule automation | ✅ | ✅ |
| Real-time effects / particles | ✅ | ✅ |
| Global shortcuts | ✅ | ✅ |
| System monitor panel | ✅ | ✅ |
| Lock-screen snapshot sync | ✅ | ✅ |
| Game / full-screen auto-pause | ✅ | ✅ |
| GitHub Releases update check | ✅ | — |
| **Metal shader procedural wallpapers** | — | ✅ |
| **Wallpaper-Engine scene rendering** | — | ✅ |
| **Local copied project-folder import** | — | ✅ |
| **Steam Workshop URL preview** | — | ✅ |
| **Workshop online browse/download** | — | ✅ (direct distribution only) |

## How the split is implemented

Pro-only sources are gated with `#if !LITE_BUILD`. The Lite scheme
(`LiveWallpaperLite`) sets the `LITE_BUILD` compilation condition, so the Metal scene
renderer, shader pipeline, local-import, and Workshop code are compiled
out of the Lite binary entirely — they aren't merely hidden.

The runtime source of truth for what an edition exposes is
[`ProductCapabilities.swift`](../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

The GitHub Releases launch/manual update check belongs to the public Lite build.
Pro currently has no in-app updater; removing the unused Sparkle integration did
not silently replace it with Lite's release channel.

## Licensing

- **Lite** is MIT and distributed here on GitHub Releases.
- **Pro** is the full edition. The MIT [`LICENSE`](../LICENSE) covers the entire
  repository, including the Pro-only modules.
