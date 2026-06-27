<div align="center">

<img src="docs/images/loomscreen-logo.png" width="128" alt="Loomscreen" />

# Loomscreen

### Living wallpapers for macOS — videos, web pages, shaders, and Wallpaper-Engine scenes, on every display.

[![License: MIT](https://img.shields.io/badge/Lite-MIT-yellow.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue.svg)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-purple.svg)](#requirements)
[![Release](https://img.shields.io/github/v/release/Paradox07127/Loomscreen?include_prereleases&sort=semver)](https://github.com/Paradox07127/Loomscreen/releases/latest)

**[⬇ Download](https://github.com/Paradox07127/Loomscreen/releases/latest)** ·
**[✨ Features](docs/features.md)** ·
**[⚖ Lite vs Pro](docs/lite-vs-pro.md)** ·
**[🛠 Build](docs/building.md)** ·
[简体中文](README.zh-Hans.md)

</div>

---

Loomscreen is a menu-bar app that turns your desktop into a living scene and keeps
out of your way. Point it at a video, a web page, an Apple Aerial, a Metal shader,
or a Wallpaper-Engine project — it renders across every connected display, pauses
itself when a game goes full-screen, and sips power the rest of the time.

It comes in two editions built from one codebase:

<table>
<tr>
<td width="50%" valign="top">

### 🆓 Loomscreen Lite
**Free · open-source (MIT)**

The lightweight runtime. Video, HTML, and Apple Aerials wallpapers at full
fidelity — same playback engine as Pro, just without the heavy renderers.
Distributed here on GitHub Releases.

</td>
<td width="50%" valign="top">

### ⭐ Loomscreen Pro
**Full edition**

Everything in Lite plus the Metal scene/shader renderer, Wallpaper-Engine
scene playback, local project import, Workshop preview, and developer tools.

</td>
</tr>
</table>

> Lite is a **lightweight runtime, not a stripped-down UI** — video / HTML / Aerials
> look and behave exactly like Pro. The split is about which renderers ship, not
> which buttons you get. See the full [Lite vs Pro matrix](docs/lite-vs-pro.md).

> 🚧 **0.x line.** Loomscreen is iterating fast; the config schema and UI may shift
> between `0.y` releases until it stabilizes at `1.0.0`. Feedback and bug reports are
> very welcome — open an [issue](https://github.com/Paradox07127/Loomscreen/issues).

## ✨ Highlights

- 🎬 **Any source** — local videos, web pages / HTML, Apple Aerials, Metal shaders, and Wallpaper-Engine scenes (Pro).
- 🖥 **Every display** — independent wallpapers per monitor, with playlists and time-of-day scheduling.
- 🎛 **Effects** — real-time post effects, particle overlays, and weather-reactive scenes.
- 🔖 **Bookmarks & playlists** — favorite a wallpaper, rotate a set, shuffle on a schedule.
- 🎮 **Stays out of the way** — auto-pauses for full-screen games and apps; ProMotion-aware; light on battery.
- 🔄 **Quiet updates** — one GitHub-Releases check per launch (12 h throttle), no telemetry, no background polling.

→ Full tour with the how and why in **[docs/features.md](docs/features.md)**.

## 🚀 Quick start

1. Download the latest `Loomscreen-x.y.z.dmg` (Lite) from **[Releases](https://github.com/Paradox07127/Loomscreen/releases/latest)**.
2. Open the DMG and drag **Loomscreen.app** into `/Applications`.
3. Because the build is ad-hoc signed (no paid Apple Developer ID yet), clear the
   Gatekeeper quarantine **once** in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
4. Launch it — the icon lands in your menu bar.

Full install notes, updates, and troubleshooting: **[docs/install.md](docs/install.md)**.

## Requirements

- macOS 14.0 (Sonoma) or later
- **Apple Silicon Mac** — Intel is not supported
- Xcode 16.2+ to build from source

## 🛠 Build from source

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

Pick the **LiveWallpaperLite** scheme for Lite (`LITE_BUILD`; Pro-only sources gated
by `#if !LITE_BUILD` are excluded) or **LiveWallpaper** for the full build, then `⌘R`.
Details and CI notes: **[docs/building.md](docs/building.md)** · **[RELEASING.md](RELEASING.md)**.

## Contributing · Security · License

- **PRs and issues welcome.** Run `xcodebuild test` on the `LiveWallpaper` scheme and
  `xcodebuild build` on `LiveWallpaperLite` before opening a PR — both must pass. The
  test suite enforces runtime invariants.
- **Security:** use GitHub's [private vulnerability reporting](https://github.com/Paradox07127/Loomscreen/security/advisories/new), not public issues.
- **License:** MIT — see [LICENSE](LICENSE). Covers the full codebase, including
  Pro-only modules gated by `#if !LITE_BUILD`.

<div align="center"><sub>Loomscreen does not bundle Wallpaper Engine content or bypass creator permissions — you are responsible for the rights to any wallpapers you import.</sub></div>
