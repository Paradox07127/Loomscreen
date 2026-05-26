# LiveWallpaper · Loomscreen

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-purple.svg)](#requirements)
[![Release](https://img.shields.io/github/v/release/Paradox07127/LiveWallpaper?include_prereleases&sort=semver&filter=loomscreen-*)](https://github.com/Paradox07127/LiveWallpaper/releases)

A macOS menu bar app that plays animated wallpapers — videos and web pages — across every connected display.

This repository is the source of two macOS SKUs that ship from a single codebase:

| Build | Distribution | Status |
|---|---|---|
| **LiveWallpaper** | Commercial Pro edition; distributed separately. | All features, including Metal shader wallpapers, third-party scene-format rendering / import, and the developer-tools harness. |
| **Loomscreen** | **Open-source Lite edition. MIT licensed.** Distributed via GitHub Releases. | Video, HTML/Web, Aerials, particles, schedules, playlists — the four Pro-only renderers / tools listed above are compiled out. |

"LiveWallpaper" is also the **internal codename** of this repository. "Loomscreen" is the **public product name** of the open-source release — same codebase, slimmer ship.

> ⚠️ Loomscreen is on the **0.x** semver line. Features and configuration shape may change between `0.y` and `0.(y+1)`. The schema gets locked when the surface reaches `1.0.0`.

## Loomscreen (Lite edition)

### Download

> **Releases:** https://github.com/Paradox07127/LiveWallpaper/releases

1. Download the latest `Loomscreen-x.y.z.dmg` from GitHub Releases.
2. Open the DMG and drag **Loomscreen.app** into `/Applications`.
3. Loomscreen ships **ad-hoc signed** — no Apple Developer ID yet, so macOS Gatekeeper quarantines it on first launch. Run **once** from Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
   This tells macOS you trust the binary. Skip the step and double-click silently fails with "*Loomscreen can't be opened…*".
4. Double-click `Loomscreen.app`. The Loomscreen icon appears in the menu bar; click it to add wallpapers.

### Troubleshooting first launch

- **"Loomscreen is damaged and can't be opened"** — Gatekeeper's wording for the quarantine flag. Re-run the `xattr` command above (with `sudo` if it still trips).
- **Permission dialogs on first use** — Loomscreen asks for Desktop / Documents / Downloads / Location / System Settings access only as features need them. Grant per prompt; revoke later in `System Settings → Privacy & Security`.
- **Both Loomscreen and LiveWallpaper Pro installed?** — They coexist cleanly: distinct bundle IDs (`com.loomscreen` vs `Taijia.LiveWallpaper`), distinct file types (`.loomscreen` vs `.lwconfig`), distinct icons in Dock and Finder.

### Updates

Loomscreen checks GitHub Releases on app launch (rate-limited to **once every 12 hours** per machine — no background polling, no telemetry). When a newer release is available you'll see a "*New version available*" prompt that opens the GitHub Releases page in your browser. You can also trigger a check manually from **Settings → About**.

### Feature parity matrix

| Capability                                          | LiveWallpaper Pro | Loomscreen Lite |
|---|:---:|:---:|
| Video wallpapers (MP4 / MOV / AVI)                  | ✅ | ✅ |
| HTML / Web (WKWebView) wallpapers                   | ✅ | ✅ |
| Apple Aerials browser                               | ✅ | ✅ |
| Multi-display, per-screen configuration             | ✅ | ✅ |
| Bookmarks library (one-click reapply)               | ✅ | ✅ |
| Playlists, shuffle, drag-reorder, scheduling        | ✅ | ✅ |
| Real-time CIFilter pipeline (blur / vignette / …)   | ✅ | ✅ |
| Particle overlays (snow / rain / sakura / …)        | ✅ | ✅ |
| Weather-reactive driver                             | ✅ | ✅ |
| System monitor (CPU / GPU / RAM)                    | ✅ | ✅ |
| Lock-screen snapshot frames                         | ✅ | ✅ |
| Inline inspector preview                            | ✅ | ✅ |
| Global keyboard shortcuts                           | ✅ | ✅ |
| **Metal shader procedural wallpapers**              | ✅ | — |
| **Third-party scene-format rendering**              | ✅ | — |
| **Third-party scene-format import (`.pkg`)**        | ✅ | — |
| **Developer-tools harness**                         | ✅ | — |

Lite is a **lightweight runtime, not a UI castration**: video / HTML / Aerials fidelity matches Pro one-for-one. The capability set is defined in [ProductCapabilities.swift](Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## Features (full codebase)

- **Multi-Type Wallpapers** — Video (MP4/MOV/AVI), HTML/Web (WKWebView), Metal shader (procedural GPU art), compatible third-party community scene packages (folder import; `.pkg` extraction when present)
- **Multi-Display** — Independent configuration per screen
- **Bookmarks** — Save any video / web page / shader once, re-apply to any display in one click (sidebar Library, inspector header)
- **HTML Trust Model** — Untrusted remote URLs run with JavaScript disabled by default; one-click `Trust this site` to allow
- **Apple Aerials** — Browse and apply Apple's downloaded aerial wallpapers (after one-time directory grant)
- **Playlist & Scheduling** — Multi-video playlists with shuffle, drag-to-reorder, and time-of-day scheduling
- **Real-Time Effects** — CIFilter pipeline: blur, saturation, brightness, color temperature, vignette, rain-on-glass
- **Particle Overlays** — Snow, rain, bokeh, fireflies, falling leaves, sakura
- **Weather-Reactive** — Optionally drive particles + color from real-time conditions (Open-Meteo, no key)
- **Power Aware** — Pause on battery, full-screen app detection, lock-screen frame capture
- **Playback Control** — Speed (0.5x-2.0x), frame rate limiting, fit modes (Fill/Fit/Stretch), per-screen mute
- **System Monitoring** — System-wide CPU/GPU/memory/thermal + per-app metrics, estimated render FPS
- **Adaptive macOS UI** — native Liquid Glass on macOS 26, material-based fallbacks on macOS 14 and 15. The highest-fidelity path is the default on every supported OS; no per-user configuration.
- **Swift 6 Strict Concurrency** — Compile-time data race safety
- **800+ Unit Tests** — Policies, decoders, bookmarks, HTML trust, schedule, playlist, scene import/rendering, macOS compatibility policy, in-app update checker, and release regressions
- **Zero Dependencies** — Pure Apple-native frameworks

## Requirements

- macOS 14.0 (Sonoma) or later
- **Apple Silicon Mac required.** Intel Macs are not supported.
- Xcode 16.2+ (for building from source)

## Building from source

1. Open `LiveWallpaper.xcodeproj` in Xcode.
2. Pick a scheme:
   - **LiveWallpaper** — full Pro build.
   - **LiveWallpaperLite** — Loomscreen Lite build. `LITE_BUILD` flag is set; Pro-only sources gated by `#if !LITE_BUILD` are excluded.
3. Build and run (`⌘R`).
4. Click the menu bar icon → select a display → choose a video.

> The two schemes share `DerivedData/.../XCBuildData/build.db`, so don't build them in parallel. Run sequentially or use distinct `-derivedDataPath` paths.

## Documentation

- [CLAUDE.md](CLAUDE.md) — Conventions and runtime contracts contributors must follow.
- [CHANGELOG.md](CHANGELOG.md) — Loomscreen release notes (Lite). Pro release notes are tracked separately.

## Release tooling

- [scripts/release-loomscreen.sh](scripts/release-loomscreen.sh) — Build, ad-hoc sign, and package a Loomscreen DMG. `--version X.Y.Z` (required), `--dry-run` skips DMG generation.
- [scripts/release_candidate_check.sh](scripts/release_candidate_check.sh) — Automated local release-candidate checks (Hardened Runtime, Privacy Manifest, i18n, static audit). `REQUIRE_DEVELOPER_ID=1` on a signing machine fails fast if the Developer ID Application certificate is missing.
- [.github/workflows/release-loomscreen.yml](.github/workflows/release-loomscreen.yml) — Push a `loomscreen-v*.*.*` tag to trigger an automated archive → sign → DMG → publish run.

## Contributing

PRs and issues welcome. Read [CLAUDE.md](CLAUDE.md) first — it documents the runtime invariants, conventions, and build gates enforced by the test suite. Run `xcodebuild test` on the `LiveWallpaper` scheme and `xcodebuild build` on `LiveWallpaperLite` locally before opening a PR.

## Security

For security issues, please use GitHub's [private vulnerability reporting](https://github.com/Paradox07127/LiveWallpaper/security/advisories/new) instead of opening a public issue.

## Trademarks

"Wallpaper Engine" is a trademark of Kaboom Productions. "Steam" and "Steam Workshop" are trademarks of Valve Corporation. This project is independent open-source software, not affiliated with, endorsed by, or sponsored by either company. References elsewhere in this codebase to third-party scene formats are for interoperability documentation purposes only (nominative fair use).

## License

Released under the **MIT License** — see [LICENSE](LICENSE). The full LiveWallpaper codebase (including Pro-only modules gated by `#if !LITE_BUILD`) is covered by the same license.
