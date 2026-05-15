# LiveWallpaper

A macOS menu bar application that plays video, HTML, Metal shader, and compatible Wallpaper Engine scene content as animated desktop wallpapers across multiple displays.

## Features

- **Multi-Type Wallpapers** — Video (MP4/MOV/AVI), HTML/Web (WKWebView), Metal shader (procedural GPU art), compatible Wallpaper Engine scenes (Workshop folder import; `scene.pkg` extraction when present)
- **Multi-Display** — Independent configuration per screen
- **Bookmarks** — Save any video / web page / shader once, re-apply to any display in one click (sidebar Library, inspector header, menu bar)
- **HTML Trust Model** — Untrusted remote URLs run with JavaScript disabled by default; one-click `Trust this site` to allow
- **Apple Aerials** — Browse and apply Apple's downloaded aerial wallpapers (after one-time directory grant)
- **Playlist & Scheduling** — Multi-video playlists with shuffle, drag-to-reorder, and time-of-day scheduling
- **Real-Time Effects** — CIFilter pipeline: blur, saturation, brightness, color temperature, vignette, rain-on-glass
- **Particle Overlays** — Snow, rain, bokeh, fireflies, falling leaves, sakura
- **Weather-Reactive** — Optionally drive particles + color from real-time conditions (Open-Meteo, no key)
- **Power Aware** — Pause on battery, full-screen app detection, lock-screen frame capture
- **Playback Control** — Speed (0.5x-2.0x), frame rate limiting, fit modes (Fill/Fit/Stretch), per-screen mute
- **System Monitoring** — System-wide CPU/GPU/memory/thermal + per-app metrics, estimated render FPS
- **Liquid Glass UI** — macOS 26 native design system
- **Swift 6 Strict Concurrency** — Compile-time data race safety
- **546 Unit Tests** — Policies, decoders, bookmarks, HTML trust, schedule, playlist, WPE import/rendering, and release regressions
- **Zero Dependencies** — Pure Apple-native frameworks

## Requirements

- macOS 26.0 (Tahoe) or later
- Apple Silicon recommended
- Xcode 16.2+ (for building)

## Getting Started

1. Open `LiveWallpaper.xcodeproj` in Xcode
2. Build and run (Cmd+R)
3. Click the menu bar icon → select a display → choose a video

## Documentation

- [DESIGN.md](DESIGN.md) — One-page architecture reference: layers, flows, persistence keys, performance contracts

## Release Readiness

- `docs/qa/release-qa-matrix.md` — Manual release-candidate QA matrix.
- `docs/qa/release-blockers.md` — P0/P1 blocker triage.
- `docs/qa/privacy-data-map.md` — Privacy and data-flow review source.
- `docs/qa/packaging-notarization-checklist.md` — Developer ID signing and notarization gate.
- `docs/qa/performance-stability-protocol.md` — Performance and soak-test protocol.
- `docs/qa/rc-signoff-template.md` — Final release candidate sign-off template.
- `docs/legal/privacy-policy-draft.md` — Draft privacy policy for product/legal review.
- `docs/legal/terms-of-use-draft.md` — Draft terms for product/legal review.
- `scripts/release_candidate_check.sh` — Automated local release-candidate checks; set `REQUIRE_DEVELOPER_ID=1` on the signing machine.
