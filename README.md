# LiveWallpaper · Loomscreen

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-purple.svg)](#requirements)
[![Release](https://img.shields.io/github/v/release/Paradox07127/Loomscreen?include_prereleases&sort=semver&filter=loomscreen-*)](https://github.com/Paradox07127/Loomscreen/releases)

> English | [简体中文](README.zh-Hans.md)

> 🚧 **Active development.** Loomscreen is being iterated continuously. Feedback, bug reports, and PRs are very welcome — open an [issue](https://github.com/Paradox07127/Loomscreen/issues) or start a [discussion](https://github.com/Paradox07127/Loomscreen/discussions).

A macOS menu bar app that plays animated wallpapers — videos and web pages — across every connected display.

This repository ships two SKUs from a single codebase:

| Build | License | Notes |
|---|---|---|
| **LiveWallpaper Pro** | Commercial; distributed separately | Full features |
| **Loomscreen Lite** | **MIT, open-source via GitHub Releases** | Lightweight runtime; Pro-only renderers, local-project import, and dev tools compiled out |

> ⚠️ Loomscreen is on the **0.x** semver line — features and configuration shape may change between `0.y` releases until the surface stabilizes at `1.0.0`.

## Quick start

1. Download `Loomscreen-x.y.z.dmg` from [Releases](https://github.com/Paradox07127/Loomscreen/releases).
2. Open the DMG, drag **Loomscreen.app** into `/Applications`.
3. Run **once** in Terminal — Loomscreen is ad-hoc signed (no paid Apple Developer ID yet), so macOS Gatekeeper quarantines the binary on first launch:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Double-click `Loomscreen.app`. The icon appears in your menu bar.

Loomscreen self-updates by checking GitHub Releases once per launch (12 h throttle, no background polling, no telemetry). Trigger manually from **Settings → About**.

## Feature parity

| Capability | Pro | Lite |
|---|:---:|:---:|
| Video / HTML / Apple Aerials wallpapers | ✅ | ✅ |
| Multi-display, playlists, scheduling, bookmarks | ✅ | ✅ |
| Real-time effects, particle overlays, weather-reactive | ✅ | ✅ |
| **Metal shader procedural wallpapers** | ✅ | — |
| **Local copied project-folder import** | ✅ | — |
| **Compatible Scene project rendering** | ✅ | — |
| **Steam Workshop URL preview** (direct-distribution Pro only) | ✅ | — |
| **Developer-tools harness** | ✅ | — |

Lite is a **lightweight runtime, not a UI castration** — video / HTML / Aerials fidelity matches Pro one-for-one. The authoritative capability matrix lives in [ProductCapabilities.swift](Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## LiveWallpaper Pro local project import

LiveWallpaper Pro can scan and import local project folders copied from a Windows Wallpaper Engine library. The supported workflow:

1. On Windows, use Steam / Wallpaper Engine to download wallpapers you are allowed to use.
2. Copy the local folder containing numbered project folders to your Mac.
3. In Pro, choose that folder. The app scans local `project.json` files and prepares supported projects for playback.

LiveWallpaper does **not** bundle Wallpaper Engine content or bypass creator permissions. Users are responsible for the rights to copy and use any imported project files. Projects requiring Windows executables / `.dll` plugins are skipped on macOS.

## LiveWallpaper Pro Steam Workshop preview

The direct-distribution Pro build (not the Mac App Store / Lite variants) can fetch official metadata for a Steam Workshop item from a pasted URL — title, preview image, file size, last-updated time — by calling Valve's public `ISteamRemoteStorage/GetPublishedFileDetails` endpoint directly over HTTPS. **No Steam sign-in, no API key, no Loomscreen-side backend.**

Workshop content is sandboxed when it eventually runs: every Workshop-sourced HTML wallpaper is forced into a fresh `WKWebsiteDataStore.nonPersistent()` session with a strict Content-Security-Policy that blocks `<frame>`, `<object>`, `<base>`, and `<form>` exfiltration paths.

What we deliberately don't do:

- Show a Steam password field anywhere in Loomscreen.
- Collect, store, log, proxy, or transmit your Steam password, Steam Guard codes, or session tokens.
- Embed a shared Steam Web API key, or send your Workshop requests through a Loomscreen server.

Actually downloading Workshop content needs your own Steam account + the official Valve SteamCMD installed via Homebrew or Valve's tarball — that opt-in setup ships in a later release. Until then, the per-row "Open in Steam" action hands the user off to the real Steam client.

## Requirements

- macOS 14.0 (Sonoma) or later
- **Apple Silicon Mac required** — Intel Macs are not supported
- Xcode 16.2+ (for building from source)

## Building from source

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

Pick the **LiveWallpaperLite** scheme for the Loomscreen Lite build (`LITE_BUILD` flag set; Pro-only sources gated by `#if !LITE_BUILD` are excluded), or **LiveWallpaper** for the full Pro build. `⌘R` to run.

Don't build both schemes in parallel — they share the same `XCBuildData/build.db`.

## Contributing · Security · License

- **PRs and issues welcome.** Run `xcodebuild test` on the `LiveWallpaper` scheme + `xcodebuild build` on `LiveWallpaperLite` before opening a PR; both must succeed. The test suite enforces runtime invariants — if a PR needs to diverge from them, flag it in the description.
- **Security issues:** use GitHub's [private vulnerability reporting](https://github.com/Paradox07127/Loomscreen/security/advisories/new) instead of public issues.
- **License:** MIT — see [LICENSE](LICENSE). The full LiveWallpaper codebase (including Pro-only modules gated by `#if !LITE_BUILD`) is covered.

