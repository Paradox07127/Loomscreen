# Releasing Loomscreen (Lite)

Both SKUs ship as ad-hoc-signed DMGs (no paid Apple Developer ID yet). The
shared packaging engine is `scripts/release-app.sh --sku {lite,pro}`:

- **Lite** (`LiveWallpaperLite` → `Loomscreen.app`, `com.loomscreen`, tag
  `loomscreen-v<X.Y.Z>`). Pushing that tag triggers
  `.github/workflows/release-loomscreen.yml`, which builds + publishes a DMG +
  SHA-256. `scripts/release-loomscreen.sh` is a thin wrapper for `--sku lite`.
- **Pro** (`LiveWallpaper` → `LiveWallpaper.app`, `Taijia.LiveWallpaper`, tag
  `v<X.Y.Z>`). No CI workflow yet — package locally with `--sku pro`.

Versioning is SemVer on the `0.x` line: any `0.y` → `0.(y+1)` bump may break
the config schema / UI / feature gating until `1.0.0`.

## Pre-release checklist

1. **Land all in-flight work; tree must be clean.** `release-loomscreen.sh`
   aborts on uncommitted changes (`git diff --quiet HEAD`).
2. **Bump the Lite version.** Set `MARKETING_VERSION` to the new `X.Y.Z` in
   both `LiveWallpaperLite` configs in `LiveWallpaper.xcodeproj/project.pbxproj`
   (Debug + Release — currently the two `MARKETING_VERSION = 0.1.0` entries).
   The packaging script fails if `--version` ≠ the scheme's `MARKETING_VERSION`.
3. **Finalize the changelog.** Rename `## [Unreleased]` → `## [X.Y.Z] — <date>`
   in `CHANGELOG.md`, add a fresh empty `[Unreleased]`, and add the footer
   compare links. Only list changes that ship in Lite — the WPE renderer is
   Pro-only (`#if !LITE_BUILD`).
4. **Run the release-candidate checks** (see below). Resolve blockers.
5. **Dry-run the packager:** `scripts/release-loomscreen.sh --version X.Y.Z --dry-run`
   (archives + signs + verifies bundle identity, skips DMG and RC checks).
6. **Commit** the version bump + changelog.

## Release-candidate checks

`scripts/release_candidate_check.sh` runs: Release build-settings sanity
(Hardened Runtime on), privacy-manifest lint, unit tests
(`-only-testing:LiveWallpaperTests`), `i18n_guard.sh` (scope=all), xcstrings
format `--check`, `audit.sh static`, `git diff --check`, and a bookmark-resolver
audit. Run it directly, or as a sub-step of the packager.

Quick lightweight subset (no Xcode build):

```sh
git diff --check
I18N_GUARD_SCOPE=all scripts/i18n_guard.sh
swift scripts/format_xcstrings.swift --check \
  LiveWallpaper/Resources/Localizable.xcstrings \
  LiveWallpaper/Resources/InfoPlist.xcstrings
scripts/audit.sh static
```

To auto-fix xcstrings formatting, drop the `--check`. `audit.sh static` only
writes reports under `.audit/`; it does not fail the build.

> **Gate caveat:** the CI release path runs the packager with
> `GITHUB_ACTIONS=true`, which **skips** `release_candidate_check.sh` (GitHub
> runners lack the signing cert and ripgrep nuances). So the i18n / xcstrings /
> unit-test gates only hard-block a **local** release run — they will not stop a
> tag-push CI build. Treat them as quality gates to clear before tagging, not as
> a safety net the tag relies on.

## Cutting the release

Preferred — let CI build and publish:

```sh
git tag -a loomscreen-vX.Y.Z -m "Loomscreen X.Y.Z"
git push origin loomscreen-vX.Y.Z
```

Or build locally (requires a clean tree and matching `MARKETING_VERSION`).
Add `--skip-checks` to bypass the RC gate the same way CI does (e.g. when the
i18n guard is red on pre-existing, CI-ignored strings):

```sh
scripts/release-app.sh --sku lite --version X.Y.Z   # -> build/release/Loomscreen-X.Y.Z.dmg
scripts/release-app.sh --sku pro  --version X.Y.Z   # -> build/release/LiveWallpaper-X.Y.Z.dmg
```

Publish Lite to GitHub Releases:

```sh
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg \
  build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  --title "Loomscreen X.Y.Z" \
  --notes-file CHANGELOG.md
```

## Post-release

- Smoke-test on a clean Mac. Because the build is ad-hoc signed, first launch
  needs: `xattr -dr com.apple.quarantine /Applications/Loomscreen.app`.
- Confirm the in-app update checker (Settings → About → "Check Now") sees the
  new release.
