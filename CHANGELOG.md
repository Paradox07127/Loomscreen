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

[Unreleased]: https://github.com/Paradox07127/LiveWallpaper/compare/loomscreen-v0.1.0...HEAD
[0.1.0]: https://github.com/Paradox07127/LiveWallpaper/releases/tag/loomscreen-v0.1.0
