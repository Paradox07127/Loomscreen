# Releasing Loomscreen

This is the maintainer checklist for a manual `0.x` release. Public builds are
ad-hoc signed and distributed from GitHub Releases as DMGs.

## Current updater boundary

Release delivery uses GitHub Releases and remains manual: users download the
new DMG and replace the installed app. The Lite app keeps its launch-time and
About-panel GitHub update checks; neither SKU auto-installs updates.

## Version checklist

1. Set `MARKETING_VERSION` to `X.Y.Z` for both app targets:
   `LiveWallpaper` and `LiveWallpaperLite`.
2. Keep `CURRENT_PROJECT_VERSION` unchanged unless the build-number policy
   changes.
3. Update `CHANGELOG.md` with `## [X.Y.Z] — YYYY-MM-DD` and footer compare
   links.
4. Make sure `LiveWallpaper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   is included when Swift package pins changed.
5. Commit the version and documentation changes before packaging. The local
   packaging script refuses a dirty tree.

## Preflight

Run the complete sequential gate before creating artifacts:

```sh
scripts/release_candidate_check.sh
```

The script runs the Core, ProWPE, and VideoWeb package tests, signed Pro tests,
the Lite build, release build-setting/privacy checks, and `git diff --check`.
Package, Pro, and Lite checks are deliberately sequential to avoid shared build
database and compiler-cache contention. Maintainer-local audit/i18n helpers may
be run in addition, but are not required by this portable gate.

## Manual packaging

The tracked, secret-free packaging helper produces:

- `build/release/Loomscreen-X.Y.Z.dmg`
- `build/release/Loomscreen-X.Y.Z.dmg.sha256`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg`
- `build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256`

Expected commands:

```sh
scripts/release-app.sh --sku lite --version X.Y.Z
scripts/release-app.sh --sku pro  --version X.Y.Z
```

Validate the clean-clone tooling contract without building or signing:

```sh
scripts/release_contract_check.sh
scripts/release-app.sh --sku lite --version X.Y.Z --plan
scripts/release-app.sh --sku pro  --version X.Y.Z --plan
```

`--plan` performs no build and writes no artifact. Signing identities and any
future notarization credentials remain environment/machine inputs; they are not
stored in this repository.

The public Lite asset must be named `Loomscreen-X.Y.Z.dmg`. The Pro asset must
be named `Loomscreen-Pro-X.Y.Z.dmg`. Upload the Lite DMG first so older update
checkers that pick the first matching DMG still resolve the Lite build.

## GitHub release

Create one unified release:

```sh
gh release create loomscreen-vX.Y.Z \
  build/release/Loomscreen-X.Y.Z.dmg \
  build/release/Loomscreen-X.Y.Z.dmg.sha256 \
  build/release/Loomscreen-Pro-X.Y.Z.dmg \
  build/release/Loomscreen-Pro-X.Y.Z.dmg.sha256 \
  --title "Loomscreen X.Y.Z" \
  --notes-file <notes.md>
```

Release notes should lead with the Lite download and mention that updating is
manual: download the new DMG, replace the app in `/Applications`, then repeat
the quarantine-clear command once.

## Post-release smoke

1. Install the Lite DMG on a clean Mac.
2. Run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Loomscreen.app
   ```
3. Launch Loomscreen and confirm the menu bar app opens.
4. In **Settings -> About**, confirm the version is `X.Y.Z`.
5. Confirm **Check Now** resolves the current version through GitHub Releases.
