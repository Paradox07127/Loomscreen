#!/usr/bin/env bash
#
# Build, sign (ad-hoc), and package a Loomscreen Lite release.
#
# Loomscreen ships ad-hoc signed via GitHub Releases — no Apple Developer ID
# yet, so this script never expects a Developer ID Application certificate
# and explicitly overrides CODE_SIGN_IDENTITY="-" / CODE_SIGN_STYLE=Manual to
# stop xcodebuild from silently picking up an Apple Development cert that
# would refuse to launch on other Macs.
#
# Usage:
#   scripts/release-loomscreen.sh --version 1.0.0
#   scripts/release-loomscreen.sh --version 1.0.0 --dry-run
#
# Output:
#   build/release/Loomscreen-X.Y.Z.dmg
#   build/release/Loomscreen-X.Y.Z.dmg.sha256
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------- argument parsing ----------

VERSION=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      sed -n '3,18p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      exit 64
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "ERROR: --version is required (e.g. --version 1.0.0)" >&2
  exit 64
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: --version must be major.minor.patch (got: $VERSION)" >&2
  exit 64
fi

# ---------- environment ----------

DERIVED_DATA="${DERIVED_DATA:-/tmp/LoomscreenRelease}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

OUTPUT_DIR="$ROOT/build/release"
STAGING_DIR="$OUTPUT_DIR/staging"
ARCHIVE_PATH="$OUTPUT_DIR/Loomscreen-${VERSION}.xcarchive"
APP_PATH="$STAGING_DIR/Loomscreen.app"
DMG_PATH="$OUTPUT_DIR/Loomscreen-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

mkdir -p "$OUTPUT_DIR"

# ---------- pre-flight ----------

echo "== Pre-flight: working tree =="
if ! git diff --quiet HEAD; then
  echo "ERROR: working tree has uncommitted changes. Commit or stash first." >&2
  git status -s >&2
  exit 65
fi

echo "== Pre-flight: MARKETING_VERSION matches --version =="
PROJECT_MARKETING_VERSION="$(xcodebuild -showBuildSettings \
    -project LiveWallpaper.xcodeproj \
    -scheme LiveWallpaperLite \
    -configuration Release 2>/dev/null \
  | awk -F'= ' '/^[[:space:]]*MARKETING_VERSION =/ {gsub(/[[:space:]]+$/,"",$2); print $2; exit}')"

if [[ "$PROJECT_MARKETING_VERSION" != "$VERSION" ]]; then
  echo "ERROR: --version ($VERSION) does not match LiveWallpaperLite MARKETING_VERSION ($PROJECT_MARKETING_VERSION)." >&2
  echo "       Bump MARKETING_VERSION in project.pbxproj first, commit, then re-run." >&2
  exit 65
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "== Pre-flight: skipping release-candidate checks (--dry-run) =="
else
  echo "== Pre-flight: existing release-candidate checks =="
  REQUIRE_DEVELOPER_ID=0 scripts/release_candidate_check.sh || {
    echo "ERROR: release_candidate_check.sh failed; fix before packaging." >&2
    exit 1
  }
fi

# ---------- archive ----------

echo "== Cleaning previous artifacts =="
rm -rf "$ARCHIVE_PATH" "$STAGING_DIR" "$DMG_PATH" "$SHA_PATH"

echo "== Archiving LiveWallpaperLite (Release, ad-hoc signed) =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  > "$OUTPUT_DIR/archive.log" 2>&1 || {
    echo "ERROR: xcodebuild archive failed. Tail of log:" >&2
    tail -40 "$OUTPUT_DIR/archive.log" >&2
    exit 1
  }

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Loomscreen.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: archive did not produce Loomscreen.app at $ARCHIVED_APP" >&2
  exit 1
fi

# ---------- stage + re-sign ----------

echo "== Staging .app for packaging =="
mkdir -p "$STAGING_DIR"
ditto "$ARCHIVED_APP" "$APP_PATH"

ENTITLEMENTS="$ROOT/LiveWallpaper/LiveWallpaper.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "ERROR: entitlements file missing: $ENTITLEMENTS" >&2
  exit 1
fi

echo "== Re-signing outer .app with entitlements =="
# xcodebuild archive already inside-out signed every embedded framework
# / xpc / properly-formed bundle with CODE_SIGN_IDENTITY="-", so we only
# need to re-sign the outer .app wrapper here to attach our explicit
# entitlements file. Walking nested directories with codesign blindly
# fails on resource-only directories that carry a .bundle suffix but
# are not real NSBundles (e.g. wpe-webgl-runtime.bundle, which is a
# raw JS asset folder).
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "== Verifying signature =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5
spctl --assess --type execute --verbose "$APP_PATH" 2>&1 | tail -3 \
  || echo "  (spctl rejects ad-hoc signing as expected — users will run xattr -dr com.apple.quarantine.)"

# ---------- bundle identity sanity ----------

echo "== Bundle identity check =="
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")"

if [[ "$ACTUAL_BUNDLE_ID" != "com.loomscreen" ]]; then
  echo "ERROR: Bundle ID expected com.loomscreen, got $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "ERROR: CFBundleShortVersionString $ACTUAL_VERSION != $VERSION" >&2
  exit 1
fi
if [[ "$ACTUAL_DISPLAY_NAME" != "Loomscreen" ]]; then
  echo "ERROR: CFBundleDisplayName expected Loomscreen, got $ACTUAL_DISPLAY_NAME" >&2
  exit 1
fi
echo "  ✓ Bundle ID:        $ACTUAL_BUNDLE_ID"
echo "  ✓ DisplayName:      $ACTUAL_DISPLAY_NAME"
echo "  ✓ Short version:    $ACTUAL_VERSION"

# ---------- dry-run short-circuit ----------

if [[ "$DRY_RUN" == "1" ]]; then
  echo "== Dry run complete — skipping DMG generation =="
  echo "  Staged app: $APP_PATH"
  echo "  Archive:    $ARCHIVE_PATH"
  exit 0
fi

# ---------- DMG ----------

echo "== Adding /Applications symlink and READ-ME =="
ln -sf /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/READ ME — first launch.txt" <<EOF
Loomscreen $VERSION

This build is ad-hoc signed (Loomscreen has no paid Apple Developer ID
yet). On first launch macOS Gatekeeper will block it unless you run, one
time, in Terminal:

    xattr -dr com.apple.quarantine /Applications/Loomscreen.app

After that, double-click Loomscreen.app like any other app. Updates are
checked once per launch (throttled to 12 h) via the GitHub Releases API.

Source: https://github.com/Paradox07127/LiveWallpaper
License: MIT
EOF

echo "== Creating DMG =="
hdiutil create \
  -volname "Loomscreen" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH" \
  > "$OUTPUT_DIR/dmg.log" 2>&1 || {
    echo "ERROR: hdiutil create failed. Tail of log:" >&2
    tail -20 "$OUTPUT_DIR/dmg.log" >&2
    exit 1
  }

echo "== Computing SHA-256 =="
shasum -a 256 "$DMG_PATH" | tee "$SHA_PATH"

DMG_SIZE_MB=$(( $(stat -f%z "$DMG_PATH") / 1024 / 1024 ))

# ---------- done ----------

echo
echo "============================================================"
echo "  ✅ Loomscreen $VERSION packaged"
echo "============================================================"
echo "  DMG:      $DMG_PATH"
echo "  Size:     ${DMG_SIZE_MB} MB"
echo "  SHA-256:  $SHA_PATH"
echo
echo "  Next:"
echo "    1. Smoke-test on a clean Mac (xattr -dr com.apple.quarantine ...)"
echo "    2. gh release create loomscreen-v$VERSION \\"
echo "         $DMG_PATH \\"
echo "         $SHA_PATH \\"
echo "         --title \"Loomscreen $VERSION\" \\"
echo "         --notes-file CHANGELOG.md"
echo "============================================================"
