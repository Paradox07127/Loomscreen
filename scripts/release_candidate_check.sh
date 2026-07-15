#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperReleaseCandidateCheck}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

echo "== Release build settings =="
xcodebuild -showBuildSettings \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  | tee /tmp/livewallpaper-release-build-settings.txt \
  | rg "PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|CURRENT_PROJECT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_HARDENED_RUNTIME|CODE_SIGN|DEVELOPMENT_TEAM|ENABLE_APP_SANDBOX|ENABLE_USER_SELECTED_FILES|ENTITLEMENTS"

if ! rg -q "ENABLE_HARDENED_RUNTIME = YES" /tmp/livewallpaper-release-build-settings.txt; then
  echo "ERROR: Release Hardened Runtime is not enabled." >&2
  exit 1
fi

echo "== Privacy manifest =="
PRIVACY_MANIFEST="LiveWallpaper/PrivacyInfo.xcprivacy"
if [[ ! -f "$PRIVACY_MANIFEST" ]]; then
  echo "ERROR: Missing $PRIVACY_MANIFEST." >&2
  exit 1
fi
plutil -lint "$PRIVACY_MANIFEST"
plutil -extract NSPrivacyAccessedAPITypes raw -o - "$PRIVACY_MANIFEST" >/dev/null

if ! security find-identity -p codesigning -v | rg -q '"Developer ID Application:'; then
  if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    echo "ERROR: No Developer ID Application signing identity found on this Mac." >&2
    exit 1
  fi
  echo "WARNING: No Developer ID Application signing identity found on this Mac; notarized export must run on a signing machine." >&2
fi

# The app scheme does not include SwiftPM test products, so a green Pro test
# action cannot attest to the package boundaries. Run every package that owns a
# test target explicitly, in dependency order, before compiling either app SKU.
# Each suite gets an isolated scratch directory below the same run root. The
# loop is deliberately serial: SwiftPM dependencies and the Xcode schemes may
# otherwise contend for shared compiler/module-cache state and make failures
# timing-dependent.
PACKAGE_TEST_PATHS=(
  "Packages/LiveWallpaperCore"
  "Packages/LiveWallpaperProWPE"
  "Packages/LiveWallpaperVideoWeb"
)

echo "== Swift package tests (sequential) =="
for package_path in "${PACKAGE_TEST_PATHS[@]}"; do
  package_name="${package_path##*/}"
  package_scratch="$DERIVED_DATA/SwiftPM/$package_name"
  echo "-- $package_name --"
  if ! swift test \
    --package-path "$package_path" \
    --scratch-path "$package_scratch"; then
    echo "ERROR: $package_name tests failed; app scheme checks were not started." >&2
    exit 1
  fi
done

echo "== Unit tests (Pro scheme) =="
xcodebuild test \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:LiveWallpaperTests

# Both SKUs ship, but the Lite scheme is a different compile surface (221
# `#if LITE_BUILD` sites); the shared main build never exercises it, so a
# Lite-only break stays invisible until release. Build it here — separate
# derived data (schemes share build.db, so never concurrent). This is the
# check the dead CI used to be relied on for.
DERIVED_DATA_LITE="${DERIVED_DATA}Lite"
echo "== Build check (Lite scheme) =="
xcodebuild build \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_LITE" \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > /tmp/livewallpaper-lite-build.log 2>&1 || {
    echo "ERROR: LiveWallpaperLite build failed. Tail of log:" >&2
    tail -40 /tmp/livewallpaper-lite-build.log >&2
    exit 1
  }

# Soft purity probe: the Pro-only Metal scene renderer must be compiled OUT of
# Lite (`#if !LITE_BUILD`). A leaked symbol means the gating regressed. Warn
# only for now — Swift symbol mangling makes a hard fail risky; promote once
# proven stable.
LITE_BIN="$(find "$DERIVED_DATA_LITE/Build/Products" -type f -path '*/Contents/MacOS/*' 2>/dev/null | head -1)"
if [[ -n "$LITE_BIN" ]]; then
  if nm "$LITE_BIN" 2>/dev/null | rg -q 'WPEMetalSceneRenderer|WPEMetalRenderExecutor'; then
    echo "WARNING: Lite binary contains Pro-only WPE renderer symbols — check #if !LITE_BUILD gating." >&2
  else
    echo "  ✓ Lite binary free of Pro-only WPE renderer symbols"
  fi
fi

echo "== Diff whitespace check =="
git diff --check

echo "Release candidate checks passed."
