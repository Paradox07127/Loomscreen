# Changelog

All notable changes to **Loomscreen** (the open-source Lite edition of the
LiveWallpaper codebase) are tracked here. Format follows
[Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

Pro-edition (`LiveWallpaper.app`) release notes live separately and are not
covered by this file.

## [Unreleased]

### Added
- Loomscreen identity for the Lite target: dedicated `Info.plist`, bundle id
  `com.loomscreen`, UTI `com.loomscreen.config` (`.loomscreen` files), and a
  Loomscreen-only display name so it coexists with the Pro app on the same
  Mac without LaunchServices collisions.

### Changed
- `ConfigurationBundle.contentType` now resolves the host SKU's UTI from
  `Bundle.main.bundleIdentifier`, with SKU-prefix-guarded historical
  fallbacks so a Pro test runner never accidentally resolves a Lite UTI when
  both apps are registered, and vice versa.
- `MenuBarContent` `OSSignposter` subsystem is now bundle-derived; signpost
  events from Loomscreen show up under `com.loomscreen` in `log` / Instruments
  instead of the Pro subsystem.

## [1.0.0] — Unreleased

First public release. Will track:

- ad-hoc-signed `.dmg` published via GitHub Releases
- in-app update checker (GitHub Releases API, 12 h cadence)
- Loomscreen-specific app icon
- MIT-licensed source

[Unreleased]: https://github.com/OWNER/REPO/compare/loomscreen-v1.0.0...HEAD
[1.0.0]: https://github.com/OWNER/REPO/releases/tag/loomscreen-v1.0.0
