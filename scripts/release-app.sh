#!/usr/bin/env bash
#
# Build, sign (ad-hoc), and package a release DMG for either SKU.
#
# Both Loomscreen (Lite) and LiveWallpaper (Pro) ship ad-hoc signed — no
# paid Apple Developer ID yet — so this script overrides
# CODE_SIGN_IDENTITY="-" / CODE_SIGN_STYLE=Manual to stop xcodebuild from
# silently picking up an Apple Development cert that would refuse to launch
# on other Macs.
#
# Usage:
#   scripts/release-app.sh --sku lite --version 0.2.0
#   scripts/release-app.sh --sku pro  --version 0.2.0 --dry-run
#   scripts/release-app.sh --sku pro  --version 0.2.0 --skip-checks
#
# Output (per SKU product name):
#   build/release/<Product>-X.Y.Z.dmg
#   build/release/<Product>-X.Y.Z.dmg.sha256
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------- argument parsing ----------

SKU="lite"
VERSION=""
DRY_RUN=0
SKIP_CHECKS_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)         SKU="${2:-}"; shift 2 ;;
    --version)     VERSION="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --skip-checks) SKIP_CHECKS_FLAG=1; shift ;;
    -h|--help)     sed -n '3,18p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "ERROR: --version is required (e.g. --version 0.2.0)" >&2
  exit 64
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: --version must be major.minor.patch (got: $VERSION)" >&2
  exit 64
fi

# ---------- SKU profile ----------

case "$SKU" in
  lite)
    SCHEME="LiveWallpaperLite"
    APP_NAME="Loomscreen"          # archived .app basename (build product)
    ARTIFACT="Loomscreen"          # dmg / archive / sha basename
    VOLNAME="Loomscreen"
    BUNDLE_ID="com.loomscreen"
    DISPLAY_NAME="Loomscreen"      # expected CFBundleDisplayName
    ;;
  pro)
    SCHEME="LiveWallpaper"
    # App bundle is still LiveWallpaper.app (binary rename deferred), but the
    # artifact carries the unified Loomscreen Pro brand. The Lite updater keys
    # off the `Loomscreen-` prefix + `-Pro-` exclusion, so this name matters.
    APP_NAME="LiveWallpaper"
    ARTIFACT="Loomscreen-Pro"
    VOLNAME="Loomscreen Pro"
    BUNDLE_ID="Taijia.LiveWallpaper"
    DISPLAY_NAME="LiveWallpaper"
    ;;
  *)
    echo "ERROR: --sku must be 'lite' or 'pro' (got: $SKU)" >&2
    exit 64
    ;;
esac

# ---------- environment ----------

DERIVED_DATA="${DERIVED_DATA:-/tmp/${ARTIFACT}Release}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

OUTPUT_DIR="$ROOT/build/release"
STAGING_DIR="$OUTPUT_DIR/staging-$ARTIFACT"
ARCHIVE_PATH="$OUTPUT_DIR/${ARTIFACT}-${VERSION}.xcarchive"
APP_PATH="$STAGING_DIR/${APP_NAME}.app"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT}-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

mkdir -p "$OUTPUT_DIR"

# ---------- pre-flight ----------

echo "== [$SKU] Pre-flight: working tree =="
if ! git diff --quiet HEAD; then
  echo "ERROR: working tree has uncommitted changes. Commit or stash first." >&2
  git status -s >&2
  exit 65
fi

echo "== [$SKU] Pre-flight: MARKETING_VERSION matches --version =="
PROJECT_MARKETING_VERSION="$(xcodebuild -showBuildSettings \
    -project LiveWallpaper.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release 2>/dev/null \
  | awk -F'= ' '/^[[:space:]]*MARKETING_VERSION =/ {gsub(/[[:space:]]+$/,"",$2); print $2; exit}')"

if [[ "$PROJECT_MARKETING_VERSION" != "$VERSION" ]]; then
  echo "ERROR: --version ($VERSION) does not match $SCHEME MARKETING_VERSION ($PROJECT_MARKETING_VERSION)." >&2
  echo "       Bump MARKETING_VERSION in project.pbxproj first, commit, then re-run." >&2
  exit 65
fi

SKIP_CHECKS=0
SKIP_REASON=""
if [[ "$DRY_RUN" == "1" ]]; then
  SKIP_CHECKS=1; SKIP_REASON="--dry-run"
elif [[ "$SKIP_CHECKS_FLAG" == "1" ]]; then
  SKIP_CHECKS=1; SKIP_REASON="--skip-checks (maintainer opt-out)"
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  # GitHub-hosted runners lack our signing cert and ripgrep; the RC check's
  # `xcodebuild test` would trip before running. CI gates elsewhere; local
  # maintainers gate via the unskipped path.
  SKIP_CHECKS=1; SKIP_REASON="GitHub Actions environment"
fi

if [[ "$SKIP_CHECKS" == "1" ]]; then
  echo "== [$SKU] Pre-flight: skipping release-candidate checks ($SKIP_REASON) =="
else
  echo "== [$SKU] Pre-flight: release-candidate checks =="
  REQUIRE_DEVELOPER_ID=0 scripts/release_candidate_check.sh || {
    echo "ERROR: release_candidate_check.sh failed; fix before packaging." >&2
    exit 1
  }
fi

# ---------- archive ----------

echo "== [$SKU] Cleaning previous artifacts =="
rm -rf "$ARCHIVE_PATH" "$STAGING_DIR" "$DMG_PATH" "$SHA_PATH"

echo "== [$SKU] Archiving $SCHEME (Release, ad-hoc signed) =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme "$SCHEME" \
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
  > "$OUTPUT_DIR/archive-$ARTIFACT.log" 2>&1 || {
    echo "ERROR: xcodebuild archive failed. Tail of log:" >&2
    tail -40 "$OUTPUT_DIR/archive-$ARTIFACT.log" >&2
    exit 1
  }

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: archive did not produce ${APP_NAME}.app at $ARCHIVED_APP" >&2
  exit 1
fi

# ---------- stage + re-sign ----------

echo "== [$SKU] Staging .app for packaging =="
mkdir -p "$STAGING_DIR"
ditto "$ARCHIVED_APP" "$APP_PATH"

ENTITLEMENTS="$ROOT/LiveWallpaper/LiveWallpaper.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "ERROR: entitlements file missing: $ENTITLEMENTS" >&2
  exit 1
fi

echo "== [$SKU] Re-signing outer .app with entitlements =="
# archive already inside-out signed nested bundles ad-hoc; only the outer
# wrapper needs re-signing to attach our explicit entitlements. Walking
# nested dirs blindly fails on resource-only *.bundle folders that are not
# real NSBundles.
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP_PATH"

echo "== [$SKU] Verifying signature =="
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5
spctl --assess --type execute --verbose "$APP_PATH" 2>&1 | tail -3 \
  || echo "  (spctl rejects ad-hoc signing as expected — users will run xattr -dr com.apple.quarantine.)"

# ---------- bundle identity sanity ----------

echo "== [$SKU] Bundle identity check =="
ACTUAL_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")"

if [[ "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "ERROR: Bundle ID expected $BUNDLE_ID, got $ACTUAL_BUNDLE_ID" >&2
  exit 1
fi
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "ERROR: CFBundleShortVersionString $ACTUAL_VERSION != $VERSION" >&2
  exit 1
fi
if [[ "$ACTUAL_DISPLAY_NAME" != "$DISPLAY_NAME" ]]; then
  echo "ERROR: CFBundleDisplayName expected $DISPLAY_NAME, got $ACTUAL_DISPLAY_NAME" >&2
  exit 1
fi
echo "  ✓ Bundle ID:        $ACTUAL_BUNDLE_ID"
echo "  ✓ DisplayName:      $ACTUAL_DISPLAY_NAME"
echo "  ✓ Short version:    $ACTUAL_VERSION"

# ---------- dry-run short-circuit ----------

if [[ "$DRY_RUN" == "1" ]]; then
  echo "== [$SKU] Dry run complete — skipping DMG generation =="
  echo "  Staged app: $APP_PATH"
  echo "  Archive:    $ARCHIVE_PATH"
  exit 0
fi

# ---------- DMG ----------

echo "== [$SKU] Adding /Applications symlink and READ-ME =="
ln -sf /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/READ ME — first launch.txt" <<EOF
$DISPLAY_NAME $VERSION

This build is ad-hoc signed (no paid Apple Developer ID yet). On first
launch macOS Gatekeeper will block it unless you run, one time, in Terminal:

    xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app

After that, double-click ${APP_NAME}.app like any other app.
EOF

echo "== [$SKU] Creating DMG =="
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH" \
  > "$OUTPUT_DIR/dmg-$ARTIFACT.log" 2>&1 || {
    echo "ERROR: hdiutil create failed. Tail of log:" >&2
    tail -20 "$OUTPUT_DIR/dmg-$ARTIFACT.log" >&2
    exit 1
  }

echo "== [$SKU] Computing SHA-256 =="
shasum -a 256 "$DMG_PATH" | tee "$SHA_PATH"

DMG_SIZE_MB=$(( $(stat -f%z "$DMG_PATH") / 1024 / 1024 ))

echo
echo "============================================================"
echo "  ✅ $DISPLAY_NAME $VERSION packaged ($SKU)"
echo "============================================================"
echo "  DMG:      $DMG_PATH"
echo "  Size:     ${DMG_SIZE_MB} MB"
echo "  SHA-256:  $SHA_PATH"
echo "  Tag:      loomscreen-v${VERSION} (unified release; attach both SKUs)"
echo "============================================================"
