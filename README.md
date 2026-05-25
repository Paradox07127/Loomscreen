# LiveWallpaper · Loomscreen

A macOS menu bar application that plays video, HTML, Metal shader, and compatible Wallpaper Engine scene content as animated desktop wallpapers across multiple displays.

This repository is the source of two macOS SKUs that ship from a single codebase:

| Build | Distribution | Status |
|---|---|---|
| **LiveWallpaper** | Commercial Pro edition; distributed separately. | All features below. |
| **Loomscreen** | **Open-source Lite edition. MIT licensed.** Distributed via GitHub Releases. | Lightweight runtime; Pro-only renderers compiled out. |

"LiveWallpaper" is also the **internal codename** of this repository. "Loomscreen" is the **public product name** of the open-source release — same codebase, slimmer ship.

## Loomscreen (Lite edition)

### Download

> **Stable releases:** https://github.com/OWNER/REPO/releases  *(placeholder — replace with the canonical URL once the open-source ship date is set).*

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
| **Wallpaper Engine scene rendering**                | ✅ | — |
| **Wallpaper Engine scene import (`scene.pkg`)**     | ✅ | — |
| **Developer-tools harness**                         | ✅ | — |

Lite is a **lightweight runtime, not a UI castration**: video / HTML / Aerials fidelity matches Pro one-for-one. The capability set is defined in [ProductCapabilities.swift](Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

## Features (full codebase)

- **Multi-Type Wallpapers** — Video (MP4/MOV/AVI), HTML/Web (WKWebView), Metal shader (procedural GPU art), compatible Wallpaper Engine scenes (Workshop folder import; `scene.pkg` extraction when present)
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
- **669 Unit Tests** — Policies, decoders, bookmarks, HTML trust, schedule, playlist, WPE import/rendering, macOS compatibility policy, and release regressions
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
- [DESIGN.md](DESIGN.md) — One-page architecture reference: layers, flows, persistence keys, performance contracts.
- [CHANGELOG.md](CHANGELOG.md) — Loomscreen release notes (Lite). Pro release notes are tracked separately.

## Release readiness (Pro signing path)

- [docs/qa/release-qa-matrix.md](docs/qa/release-qa-matrix.md) — Manual release-candidate QA matrix.
- [docs/qa/release-blockers.md](docs/qa/release-blockers.md) — P0/P1 blocker triage.
- [docs/qa/privacy-data-map.md](docs/qa/privacy-data-map.md) — Privacy and data-flow review source.
- [docs/qa/packaging-notarization-checklist.md](docs/qa/packaging-notarization-checklist.md) — Developer ID signing and notarization gate.
- [docs/qa/performance-stability-protocol.md](docs/qa/performance-stability-protocol.md) — Performance and soak-test protocol.
- [docs/qa/rc-signoff-template.md](docs/qa/rc-signoff-template.md) — Final release candidate sign-off template.
- [docs/legal/privacy-policy-draft.md](docs/legal/privacy-policy-draft.md) — Draft privacy policy for product / legal review.
- [docs/legal/terms-of-use-draft.md](docs/legal/terms-of-use-draft.md) — Draft terms for product / legal review.
- [scripts/release_candidate_check.sh](scripts/release_candidate_check.sh) — Automated local release-candidate checks; set `REQUIRE_DEVELOPER_ID=1` on the signing machine.

## License

Released under the **MIT License** — see [LICENSE](LICENSE). The full LiveWallpaper codebase (including Pro-only modules gated by `#if !LITE_BUILD`) is covered by the same license.

Contributions welcome via GitHub issues and pull requests. Please read [CLAUDE.md](CLAUDE.md) first — it documents the runtime invariants and code-style conventions enforced by the existing test suite.
