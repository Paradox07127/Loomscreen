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

echo "== Unit tests =="
xcodebuild test \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:LiveWallpaperTests

echo "== i18n guard =="
I18N_GUARD_SCOPE=all scripts/i18n_guard.sh

echo "== Static audit =="
scripts/audit.sh static

echo "== Diff whitespace check =="
git diff --check

echo "Release candidate checks passed."
