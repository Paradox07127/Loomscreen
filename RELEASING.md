# Releasing Loomscreen

Both editions ship from one **unified GitHub Release** per version, tagged
`loomscreen-v<X.Y.Z>`, carrying both ad-hoc-signed DMGs (no paid Apple Developer
ID yet). The shared packaging engine is `scripts/release-app.sh --sku {lite,pro}`:

- **Lite** (`LiveWallpaperLite` → `Loomscreen.app`, `com.loomscreen`) →
  `Loomscreen-X.Y.Z.dmg`. `scripts/release-loomscreen.sh` is a thin wrapper for
  `--sku lite`.
- **Pro** (`LiveWallpaper` → `LiveWallpaper.app`, `Taijia.LiveWallpaper`) →
  `Loomscreen-Pro-X.Y.Z.dmg`. The app bundle is still `LiveWallpaper.app` (binary
  rename deferred); only the artifact carries the unified Loomscreen Pro brand.

> **Asset naming matters.** The Lite in-app updater
> ([`UpdateChecker`](LiveWallpaper/Infrastructure/UpdateChecker.swift)) resolves
> the DMG whose name starts with `Loomscreen-` and does **not** contain `-pro-`.
> Keep the Lite DMG named `Loomscreen-X.Y.Z.dmg` and the Pro DMG
> `Loomscreen-Pro-X.Y.Z.dmg`, and upload the **Lite DMG first** so older clients
> (which pick the first `.dmg` alphabetically) also resolve Lite.

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

> **CI is currently broken for releases.** The workflow pins `xcode-version: 16.2`,
> but `LiveWallpaperSharedUI` now needs a modern Xcode (dev builds on 26.x), so the
> clean CI archive fails to compile. GitHub has no Xcode-26 runner yet, so until the
> runner image catches up (or the workflow is repointed), **publish Lite from a
> locally-built DMG** — the same path as Pro — instead of relying on the tag-push CI.
> 0.2.0 shipped this way: `gh release create loomscreen-vX.Y.Z <local dmg> <sha>`.

Tag-push (CI auto-build) — only viable once the runner can build the current code:

```sh
git tag -a loomscreen-vX.Y.Z -m "Loomscreen X.Y.Z"
git push origin loomscreen-vX.Y.Z
```

Build both DMGs locally (requires a clean tree and matching `MARKETING_VERSION`).
Add `--skip-checks` to bypass the RC gate the same way CI does (e.g. when the
i18n guard is red on pre-existing, CI-ignored strings):

```sh
scripts/release-app.sh --sku lite --version X.Y.Z   # -> build/release/Loomscreen-X.Y.Z.dmg
scripts/release-app.sh --sku pro  --version X.Y.Z   # -> build/release/Loomscreen-Pro-X.Y.Z.dmg
```

Publish **one unified release** — Lite asset first (see the asset-naming note
above), Pro second:

```sh
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg     build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  build/release/Loomscreen-Pro-X.Y.Z.dmg build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256 \
  --title "Loomscreen X.Y.Z" \
  --notes-file <notes.md>
```

Write the notes as a download table (Lite vs Pro) plus a short "what's new" —
see the 0.2.0 release for the template.

## Post-release

- Smoke-test on a clean Mac. Because the build is ad-hoc signed, first launch
  needs: `xattr -dr com.apple.quarantine /Applications/Loomscreen.app`.
- Confirm the in-app update checker (Settings → About → "Check Now") sees the
  new release.
