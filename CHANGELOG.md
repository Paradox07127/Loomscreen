# Changelog

All notable changes to **Loomscreen** (the open-source Lite edition of the
LiveWallpaper codebase) are tracked here. Format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

While Loomscreen is on the `0.x` line the public surface is considered
unstable — any `0.y` → `0.(y+1)` bump may introduce breaking changes to
the configuration schema, UI layout, or feature gating. A `1.0.0` tag
will be cut once the surface has stabilized through real-world use.

Pro-edition (`LiveWallpaper.app`) release notes live separately and are
not covered by this file.

## [Unreleased]

## [0.2.2] — 2026-07-01

### Added
- Scene diagnostics are now included in release bug reports to improve triage for
  scene rendering issues.
- Release documentation structure was expanded (`docs/README.md`,
  `docs/screenshots.md`, `docs/quick-start.md`, `docs/troubleshooting.md`) for
  easier onboarding and publishing prep.

### Changed
- Scene and settings detail surfaces were refined for smoother workflow and clearer
  status feedback.
- Runtime session and resource handling were improved in scene/playlist paths to
  reduce stale-state issues.

### Fixed
- Multiple WPE scene-path performance and stability fixes, including rendering
  pipeline and cache behavior.
- Better diagnostics around scene project metadata parsing, custom shader paths, and
  multi-root resource resolution.
- Additional edge-case hardening for HTML playlist/session handling.

## [0.2.1] — 2026-06-29

Maintenance release. Most of this cycle's work is in the Pro-only Metal scene
renderer (large performance and GPU-memory wins) and is not listed here; the
Lite-facing changes are below.

### Added
- HTML wallpapers now transcode Ogg audio to AAC so tracks WebKit can't play
  natively still play.

### Changed
- Onboarding, scene, and settings refinements; assorted UI polish.

### Fixed
- Security-scoped bookmark resolution now routes through a single resolver that
  always observes the staleness flag, reducing "re-grant access after restart"
  cases for imported folders and authorized directories.
- Cleared remaining compiler warnings; the in-app updater resolves the Lite DMG
  on a unified release; full ja / zh-Hans / zh-Hant coverage maintained.

## [0.2.0] — 2026-06-27

App-wide UI overhaul plus a batch of stability and localization fixes. The
WPE Metal scene renderer is Pro-only (`#if !LITE_BUILD`), so its work is not
listed here.

### Added
- Design-token foundation for the app UI: a Typography scale plus semantic
  Color / Status tokens, documented in a `DESIGN.md`, with app and shared-
  package text migrated onto the tokens.
- Native Xcode-style detail inspector (`.inspector()` / AppKit split bridge)
  with a toolbar toggle that compresses the detail instead of growing the
  window.
- Scene tab as a lightweight quick-apply surface with a "Browse all"
  Workshop entry; type glyphs on installed / scene cards.
- Clearer General and Workshop settings copy with info tooltips.

### Changed
- App-wide UI unification: slimmer sidebar with status-colored row icons, a
  compact inspector, one unified glass gallery card, circular/larger header
  icon buttons, and `SettingRow` adopted across settings panels.
- Workshop online browse: debounced auto-search (Search button removed),
  full-height resizable detail panel, and the tab switcher / panel toggle
  moved into the window toolbar.
- Freeing disk space now deletes downloaded Workshop files outright instead
  of moving them to the Trash.

### Fixed
- Inspector expand/collapse animation and layout glitches (panel stays
  mounted, window no longer jumps, sidebar width pinned).
- Scene detail now scrolls at small window heights.
- Destructive buttons drop the red plate behind red text; bookmark action
  only shows when there is a project to bookmark.
- String-catalog sync: every entry translated, stale entries dropped, and
  the localization coverage suite is fully green again.

## [0.1.0] — 2026-05-25

First public release. Open-source Lite edition of the LiveWallpaper
codebase, distributed via GitHub Releases.

### Added
- Loomscreen identity for the Lite target: dedicated `Info.plist`, bundle id
  `com.loomscreen`, UTI `com.loomscreen.config` (`.loomscreen` files), and a
  Loomscreen-only display name so it coexists with the Pro app on the same
  Mac without LaunchServices collisions.
- In-app update checker: single launch-time GitHub Releases lookup throttled
  to 12 h, manual "Check Now" button from the About panel, "Skip this
  version" persistence, hostile-response defenses (URL allow-list, response
  size cap, content-type guard, generic error surface).
- ad-hoc release packaging script (`scripts/release-loomscreen.sh`) and the
  matching GitHub Actions workflow that publishes a DMG + SHA-256 on every
  `loomscreen-v*.*.*` tag push.
- MIT `LICENSE`, this `CHANGELOG`, and the Loomscreen sections of the
  `README` (download / first-launch quarantine command / Pro-vs-Lite
  feature matrix / troubleshooting).

### Changed
- `ConfigurationBundle.contentType` now resolves the host SKU's UTI from
  `Bundle.main.bundleIdentifier`, with SKU-prefix-guarded historical
  fallbacks so a Pro test runner never accidentally resolves a Lite UTI when
  both apps are registered, and vice versa.
- `MenuBarContent` `OSSignposter` subsystem and the menubar / About hero
  product label are now bundle-derived (`BundleIdentity.productDisplayName`),
  so Loomscreen renders "Loomscreen" in every locale instead of inheriting
  the Pro brand label via the shared `InfoPlist.xcstrings`.

### Fixed
- `InfoPlist.xcstrings` no longer localizes `CFBundleDisplayName` /
  `CFBundleName` to "LiveWallpaper" for every locale, which used to
  override Loomscreen's hard-coded display name at runtime.

[Unreleased]: https://github.com/Paradox07127/Loomscreen/compare/loomscreen-v0.2.2...HEAD
[0.2.2]: https://github.com/Paradox07127/Loomscreen/compare/loomscreen-v0.2.1...loomscreen-v0.2.2
[0.2.1]: https://github.com/Paradox07127/Loomscreen/compare/loomscreen-v0.2.0...loomscreen-v0.2.1
[0.2.0]: https://github.com/Paradox07127/Loomscreen/compare/loomscreen-v0.1.0...loomscreen-v0.2.0
[0.1.0]: https://github.com/Paradox07127/Loomscreen/releases/tag/loomscreen-v0.1.0
