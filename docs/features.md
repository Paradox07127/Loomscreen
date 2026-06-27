# Features

A tour of what Loomscreen does. Capabilities marked **Pro** ship only in the full
edition; everything else is in both Lite and Pro. The authoritative, code-level
matrix lives in
[`ProductCapabilities.swift`](../Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Capabilities/ProductCapabilities.swift).

> 📸 Screenshots go in [`docs/images/`](images/) — drop them in and link them under
> each section below.

## Wallpaper sources

- **Video** — local video files, decoded on the GPU and played as a seamless loop.
  RAM-resident playback keeps the loop seam smooth instead of stuttering at the wrap.
- **HTML / web** — point at a local web page or bundle; it renders in a sandboxed
  `WKWebView`. Workshop-sourced HTML runs in a non-persistent session with a strict
  Content-Security-Policy.
- **Apple Aerials** — the same aerial videos macOS ships as screensavers, as a
  wallpaper.
- **Metal shaders** *(Pro)* — procedural, code-driven wallpapers rendered directly
  with Metal.
- **Wallpaper-Engine scenes** *(Pro)* — render compatible Wallpaper-Engine `scene`
  projects (layers, particles, puppets, effects) natively on Metal.

## Across your displays

- **Per-display wallpapers** — set a different wallpaper on each connected monitor.
- **Playlists** — group wallpapers, rotate them, and shuffle.
- **Scheduling** — switch wallpapers by time of day.
- **Bookmarks** — favorite any wallpaper as a one-tap, re-applyable item.

## Effects

- **Real-time post effects** and **particle overlays** composited over the scene.
- **Weather-reactive** scenes that respond to current conditions.

## Behaves itself

- **Game / full-screen pause** — detects full-screen games and apps and suspends
  rendering so it never steals GPU from what you're doing.
- **ProMotion-aware** — adapts to the display's refresh capability.
- **Power-conscious** — holds an App-Nap assertion only while actually rendering.

## Updates & privacy

- **One check per launch** against the GitHub Releases API, throttled to 12 hours.
  Trigger manually from **Settings → About → Check Now**, and "Skip this version" to
  silence a release.
- **No telemetry, no background polling, no accounts.**

## Pro-only tools

- **Local project import** — scan and import project folders copied from a Windows
  Wallpaper Engine library. See [import notes](#local-project-import-pro).
- **Steam Workshop preview** — fetch a Workshop item's public metadata from a pasted
  URL (no Steam sign-in, no API key, no Loomscreen backend).
- **Developer tools** — a corpus playback harness and diagnostics for renderer work.

### Local project import (Pro)

1. On Windows, use Steam / Wallpaper Engine to download wallpapers you are allowed to use.
2. Copy the folder of numbered project folders to your Mac.
3. In Pro, choose that folder — it scans local `project.json` files and prepares the
   supported projects for playback.

Loomscreen does **not** bundle Wallpaper Engine content or bypass creator
permissions; you are responsible for the rights to anything you import. Projects that
need Windows executables or `.dll` plugins are skipped on macOS.

### What Loomscreen deliberately never does

- Show a Steam password field anywhere.
- Collect, store, proxy, or transmit Steam passwords, Steam Guard codes, or tokens.
- Embed a shared Steam Web API key or route your requests through a Loomscreen server.
