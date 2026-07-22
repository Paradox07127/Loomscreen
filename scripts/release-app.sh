#!/usr/bin/env bash
#
# Build, ad-hoc sign, and package a release DMG for either SKU.
#
# Both SKUs currently ship ad-hoc signed. Manual signing prevents Xcode from
# selecting an Apple Development certificate that would fail on other Macs.
#
# Usage:
#   scripts/release-app.sh --sku lite --version 0.2.0
#   scripts/release-app.sh --sku pro  --version 0.2.0 --dry-run
#   scripts/release-app.sh --sku pro  --version 0.2.0 --plan
#   scripts/release-app.sh --sku pro  --version 0.2.0 --skip-checks
#
# Output (per SKU product name):
#   build/release/<Product>-X.Y.Z.dmg
#   build/release/<Product>-X.Y.Z.dmg.sha256
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKU="lite"
VERSION=""
DRY_RUN=0
PLAN=0
SKIP_CHECKS_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)         SKU="${2:-}"; shift 2 ;;
    --version)     VERSION="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --plan)        PLAN=1; shift ;;
    --skip-checks) SKIP_CHECKS_FLAG=1; shift ;;
    -h|--help)     sed -n '3,17p' "$0"; exit 0 ;;
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

case "$SKU" in
  lite)
    SCHEME="LiveWallpaperLite"
    APP_NAME="Loomscreen"
    ARTIFACT="Loomscreen"
    VOLNAME="Loomscreen"
    BUNDLE_ID="com.loomscreen"
    DISPLAY_NAME="Loomscreen"
    ;;
  pro)
    SCHEME="LiveWallpaper"
    # The Pro bundle retains its existing name; only release artifacts use Loomscreen Pro.
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

DERIVED_DATA="${DERIVED_DATA:-/tmp/${ARTIFACT}Release}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

OUTPUT_DIR="$ROOT/build/release"
STAGING_DIR="$OUTPUT_DIR/staging-$ARTIFACT"
ARCHIVE_PATH="$OUTPUT_DIR/${ARTIFACT}-${VERSION}.xcarchive"
APP_PATH="$STAGING_DIR/${APP_NAME}.app"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT}-${VERSION}.dmg"
SHA_PATH="${DMG_PATH}.sha256"

if [[ "$PLAN" == "1" ]]; then
  echo "sku=$SKU"
  echo "scheme=$SCHEME"
  echo "app=$APP_NAME.app"
  echo "bundle_id=$BUNDLE_ID"
  echo "dmg=${ARTIFACT}-${VERSION}.dmg"
  echo "sha256=${ARTIFACT}-${VERSION}.dmg.sha256"
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

echo "== [$SKU] Pre-flight: working tree =="
if ! git diff --quiet HEAD || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "ERROR: working tree has tracked or untracked changes. Commit or stash first." >&2
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

# Local release checks attest the maintainer environment and run unless
# explicitly skipped.
SKIP_CHECKS=0
SKIP_REASON=""
if [[ "$DRY_RUN" == "1" ]]; then
  SKIP_CHECKS=1; SKIP_REASON="--dry-run"
elif [[ "$SKIP_CHECKS_FLAG" == "1" ]]; then
  SKIP_CHECKS=1; SKIP_REASON="--skip-checks (maintainer opt-out)"
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

echo "== [$SKU] Staging .app for packaging =="
mkdir -p "$STAGING_DIR"
ditto "$ARCHIVED_APP" "$APP_PATH"

echo "== [$SKU] Verifying signature =="
# Preserve Xcode's archive signature. Xcode expands build-setting placeholders
# and synthesizes ENABLE_APP_SANDBOX into the processed entitlements; re-signing
# with the raw source plist would remove the sandbox and embed literal
# `$(PRODUCT_BUNDLE_IDENTIFIER)` strings.
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5
spctl --assess --type execute --verbose "$APP_PATH" 2>&1 | tail -3 \
  || echo "  (spctl rejects ad-hoc signing as expected — users will run xattr -dr com.apple.quarantine.)"

echo "== [$SKU] Entitlement baseline (shipped app) =="
# Validate the archive's effective entitlements, not only the source plist.
scripts/check_entitlements.sh --sku "$SKU" --app "$APP_PATH"

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

if [[ "$DRY_RUN" == "1" ]]; then
  echo "== [$SKU] Dry run complete — skipping DMG generation =="
  echo "  Staged app: $APP_PATH"
  echo "  Archive:    $ARCHIVE_PATH"
  exit 0
fi

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

echo "== [$SKU] Verifying DMG =="
# Verify the packaged app before publishing its checksum.
DMG_MOUNT="$(mktemp -d /tmp/lw-dmg-verify.XXXXXX)"
if ! hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$DMG_MOUNT" >/dev/null 2>&1; then
  echo "ERROR: could not mount $DMG_PATH for verification." >&2
  rmdir "$DMG_MOUNT" 2>/dev/null || true
  exit 1
fi
DMG_VERIFY_LOG="$(mktemp -t lw-dmg-verify.XXXXXX)"
if codesign --verify --deep --strict "$DMG_MOUNT/${APP_NAME}.app" 2>"$DMG_VERIFY_LOG"; then
  echo "  ✓ DMG mounts and ${APP_NAME}.app signature verifies"
  DMG_OK=1
else
  echo "ERROR: ${APP_NAME}.app inside the DMG failed signature verification:" >&2
  cat "$DMG_VERIFY_LOG" >&2
  DMG_OK=0
fi
hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
rmdir "$DMG_MOUNT" 2>/dev/null || true
rm -f "$DMG_VERIFY_LOG"
[[ "$DMG_OK" == "1" ]] || exit 1

echo "== [$SKU] Computing SHA-256 =="
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "${DMG_PATH##*/}"
) | tee "$SHA_PATH"

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
