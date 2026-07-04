# Loomscreen

<div align="center">

<img src="docs/images/loomscreen-logo.png" width="144" alt="Loomscreen" />

### Living wallpapers for macOS — videos, web pages, shaders, and Wallpaper Engine scenes across every display.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)
![Apple%20Silicon](https://img.shields.io/badge/Apple%20Silicon-Required-purple.svg)
![License](https://img.shields.io/badge/Lite-MIT-yellow.svg)
![Release](https://img.shields.io/github/v/release/Paradox07127/Loomscreen?include_prereleases&sort=semver)

[⬇ Download](https://github.com/Paradox07127/Loomscreen/releases/latest) ·
[🧭 Docs](docs/README.md) ·
[✨ Features](docs/features.md) ·
[⚖ Lite vs Pro](docs/lite-vs-pro.md) ·
[🛠 Build](docs/building.md) ·
[🎬 Screenshots](docs/screenshots.md) ·
[🌐 中文](README.zh-Hans.md)

</div>

Loomscreen is a menu-bar-first macOS wallpaper platform that lets each connected display run its own live source. Import local videos/HTML, scan Apple Aerials, and (Pro) render procedural shaders or Wallpaper Engine scenes.

![Loomscreen main UI](docs/images/main.png)

## What you can do

- **Per-display workflow**: manage wallpapers per monitor; copy one screen setup to all screens.
- **Multiple wallpaper sources**:
  - Local **video** playback (smooth looping, multi-monitor aware).
  - Local or local-folder **web pages** (sandboxed `WKWebView`).
  - Local **Apple Aerials** library items.
  - **Shaders** (custom `.lwshader` / `.metal`) and **Wallpaper Engine scenes** (Pro).
- **Smart playback control**: playlists, schedule rotation, shuffle, prev/next, one-click global pause switch.
- **Rich inspectable tuning**: volume, frame limit, scaling, cursor follow, particles, color tweaks, weather-reactive effects.
- **Quick controls in menu bar**: add wallpaper, pause/resume globally, playback stepping, live CPU/GPU/RAM/temperature strip.
- **Persistence & portability**: bookmark favorite setups and back up/recover configuration bundles.
- **Built for laptops**: auto-pause on full-screen, game windows, window occlusion, battery mode, and per-app exceptions.
- **No telemetry by design**: no accounts, no remote analytics.

## Editions

| Edition | What you get |
|---|---|
| **Loomscreen Lite** | Video / HTML / Apple Aerials, playlists, schedule, bookmarks, shortcuts, weather-reactive effects, performance controls. |
| **Loomscreen Pro** | Everything in Lite, plus Metal procedural shaders, Wallpaper Engine scenes, local scene import, Workshop preview/download path (direct distribution), and developer tools. |

### Live preview by scenario

- Video workflow:

![Video workflow](docs/images/video.png)

- Web wallpaper workflow:

![Web workflow](docs/images/web.png)

- Scene workflow (Pro):

![Scene workflow](docs/images/scene.png)

- Workshop flow (Pro):

![Workshop flow](docs/images/workshop.png)

See full matrix: [docs/lite-vs-pro.md](docs/lite-vs-pro.md).  
Implementation note: Lite removes GPU-heavy renderer modules (`#if LITE_BUILD`) rather than hiding UI.

## Quick start

Detailed guide: [docs/quick-start.md](docs/quick-start.md)

### 1) Install

1. Download the latest `Loomscreen-*.dmg` from [Releases](https://github.com/Paradox07127/Loomscreen/releases/latest).
2. Drag **Loomscreen.app** into `/Applications`.
3. Clear Gatekeeper quarantine once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Launch Loomscreen — open its menu bar icon and start your first setup.

### 2) First launch flow

- First launch opens a short onboarding.
- Choose a source (video / web / Aerials; Pro adds Workshop shortcut) and it applies immediately.
- Open the Settings window to tune per-screen behavior (playlist/schedule/colors/effects/shortcuts).

### 3) Per-display setup

- In **Settings → Displays** pick a monitor.
- Choose wallpaper type: **Video / Web / Shader / Scene** (Lite has only available types).
- Open the preview panel to set wallpaper source and play.
- Tune playback and effects in the right inspector panel.

### 4) Quick docs index

- [docs/README.md](docs/README.md) — full docs index.
- [docs/features.md](docs/features.md) — detailed feature map by app surface and function.
- [docs/install.md](docs/install.md) — install + onboarding + first-run troubleshooting.
- [docs/quick-start.md](docs/quick-start.md) — full workflow for first-run setup.
- [docs/troubleshooting.md](docs/troubleshooting.md) — error scenarios and recovery.
- [docs/screenshots.md](docs/screenshots.md) — screenshot requirements and capture checklist.

## Updates

- One launch-time GitHub Releases check + manual check path in **Settings → About**.
- Manual updates: download the new DMG and repeat the `xattr` step once.
- Public builds do not auto-install updates yet.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon Mac (Intel is not supported)

## From source

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

- Pick scheme: **LiveWallpaperLite** (Lite), **LiveWallpaper** (Pro).

Build notes: [docs/building.md](docs/building.md).

## Contributing / security / license

- PRs are welcome. Before opening a PR: run scheme build/test flow in your local setup.
- Security issues should be reported via GitHub Security Advisories.
- License: MIT (`LICENSE`), including Pro-only modules.

## Community-friendly issue guide

- Keep bug reports minimal and reproducible:
  - macOS version + Apple Silicon chip
  - screenshot of `Loomscreen -> About`
  - exact source type (video/html/shader/scene)
  - short steps to reproduce

> Loomscreen does not ship or bypass Wallpaper Engine content. You are responsible for permission on any imported wallpapers.
