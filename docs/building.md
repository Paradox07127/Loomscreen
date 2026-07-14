# Build from source

## Requirements

- macOS 14.0+ on an **Apple Silicon** Mac
- Xcode 16.2 or later
- The **Metal Toolchain** component (Xcode 26+ ships it as a separate download):
  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```
  Without it, compiling the `.metal` shaders fails with
  `cannot execute tool 'metal' due to missing Metal Toolchain`.

## Clone & open

```bash
git clone https://github.com/Paradox07127/Loomscreen.git
cd LiveWallpaper
open LiveWallpaper.xcodeproj
```

## Schemes

| Scheme | Edition | Notes |
|---|---|---|
| `LiveWallpaperLite` | Lite | Sets `LITE_BUILD`; Pro-only sources (`#if !LITE_BUILD`) are excluded. Produces `Loomscreen.app` (`com.loomscreen`). |
| `LiveWallpaper` | Pro | Full build. Produces `LiveWallpaper.app` (`Taijia.LiveWallpaper`). |

Pick a scheme and `⌘R`.

> **Don't build both schemes in parallel** — they share the same
> `XCBuildData/build.db`.

## Before opening a PR

```bash
scripts/release_candidate_check.sh
```

The release-candidate gate runs the Core, ProWPE, and VideoWeb Swift package
tests first, then the signed Pro app tests, then the Lite build. These checks are
intentionally sequential; do not start Pro and Lite separately in parallel.
The suites enforce runtime invariants (localization coverage, particle/render
behavior, etc.); if a change needs to diverge from one, call it out in the PR
description.

## Packaging a release

See [`RELEASING.md`](../RELEASING.md) for the maintainer-only ad-hoc DMG
packaging flow, 0.2.3 preflight checklist, and current updater status.
