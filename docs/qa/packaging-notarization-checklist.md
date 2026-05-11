# LiveWallpaper Packaging And Notarization Checklist

## Current Project Findings

- Release configuration uses `LiveWallpaper/LiveWallpaper.entitlements`.
- Release configuration has `ENABLE_APP_SANDBOX = YES`.
- Release build settings report `ENABLE_HARDENED_RUNTIME = YES`; verify exported artifacts still include CodeDirectory flags `0x10000(runtime)`.
- Current local signing identity is Apple Development; public distribution still requires Developer ID Application signing.
- Release bundle identifier is `Taijia.LiveWallpaper`.
- Current marketing version is `1.0`, build number is `1`.

## Archive Gate

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -archivePath /tmp/LiveWallpaper-RC.xcarchive
```

Expected:

- Command exits 0.
- Archive exists at `/tmp/LiveWallpaper-RC.xcarchive`.
- Archive contains `Products/Applications/LiveWallpaper.app`.

## Signing Gate

Run the local release check in formal signing mode on the signing machine:

```bash
REQUIRE_DEVELOPER_ID=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
scripts/release_candidate_check.sh
```

Run:

```bash
codesign -dvvv --entitlements :- /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
codesign --verify --deep --strict --verbose=4 /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
```

Expected:

- Final signature uses Developer ID Application for public distribution.
- `com.apple.security.get-task-allow` is absent or false.
- Hardened Runtime is enabled.
- Only required entitlements are present.
- Strict verification exits 0.

## Notarization Gate

Package:

```bash
ditto -c -k --keepParent \
  /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app \
  /tmp/LiveWallpaper-RC.zip
```

Submit:

```bash
xcrun notarytool submit /tmp/LiveWallpaper-RC.zip \
  --keychain-profile "LiveWallpaper-notarytool" \
  --wait
```

Staple:

```bash
xcrun stapler staple /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
xcrun stapler validate /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
spctl -a -vv --type execute /tmp/LiveWallpaper-RC.xcarchive/Products/Applications/LiveWallpaper.app
```

Expected:

- Notary status is Accepted.
- Stapler validate exits 0.
- `spctl` accepts the app.

## Distribution Artifact Gate

If distributing a ZIP:

- ZIP must preserve app bundle.
- Downloaded ZIP must expand to a stapled app.
- App must launch from Downloads without bypassing Gatekeeper.

If distributing a DMG:

- DMG must be signed or generated after app signing.
- DMG must be notarized or contain a stapled notarized app.
- Drag-to-Applications flow must work.
