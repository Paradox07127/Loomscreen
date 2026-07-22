#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperReleaseCandidateCheck}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
MACOS_DESTINATION="platform=macOS,arch=arm64"
MACOS_ARCHIVE_DESTINATION="generic/platform=macOS"

if [[ "$DERIVED_DATA" != /* ]]; then
  echo "ERROR: DERIVED_DATA must be an absolute path outside the repository." >&2
  exit 64
fi
case "$DERIVED_DATA" in
  "$ROOT"|"$ROOT"/*)
    echo "ERROR: DERIVED_DATA must stay outside the repository." >&2
    exit 64
    ;;
esac

BUILD_SETTINGS_LOG="$(mktemp -t livewallpaper-release-build-settings.XXXXXX)"
MATRIX_BUILD_LOG="$(mktemp -t livewallpaper-link-matrix.XXXXXX)"
trap 'rm -f "$BUILD_SETTINGS_LOG" "$MATRIX_BUILD_LOG"' EXIT

fail_with_log() {
  local message="$1"
  echo "ERROR: $message Tail of log:" >&2
  tail -40 "$MATRIX_BUILD_LOG" >&2
  exit 1
}

assert_no_removed_dynamic_links() {
  local binary="$1"
  local label="$2"
  if otool -L "$binary" | grep -Eq 'Sparkle|libc\+\+'; then
    echo "ERROR: $label links a removed Sparkle/libc++ dependency." >&2
    otool -L "$binary" >&2
    exit 1
  fi
}

require_fresh_archive_path() {
  local archive_path="$1"
  local label="$2"
  if [[ "$archive_path" != /* || "$archive_path" != *.xcarchive ]]; then
    echo "ERROR: $label archive path must be an absolute .xcarchive path." >&2
    exit 64
  fi
  case "$archive_path" in
    "$ROOT"|"$ROOT"/*)
      echo "ERROR: $label archive path must stay outside the repository." >&2
      exit 64
      ;;
  esac
  if [[ -e "$archive_path" ]]; then
    echo "ERROR: $label archive path already exists; choose a clean archive path." >&2
    exit 64
  fi
}

assert_arm64_binary() {
  local binary="$1"
  local label="$2"
  if [[ "$(lipo -archs "$binary")" != "arm64" ]]; then
    echo "ERROR: $label is not exactly arm64." >&2
    lipo -archs "$binary" >&2
    exit 1
  fi
}

assert_exact_xpc_sandbox_entitlements() {
  local service="$1"
  local entitlements fingerprint
  entitlements="$(mktemp -t livewallpaper-xpc-entitlements.XXXXXX)"
  if ! codesign -d --entitlements - --xml "$service" > "$entitlements" 2>/dev/null; then
    rm -f "$entitlements"
    echo "ERROR: Could not read SceneScript XPC entitlements from $service." >&2
    exit 1
  fi
  if ! plutil -lint "$entitlements" >/dev/null; then
    rm -f "$entitlements"
    echo "ERROR: SceneScript XPC service has no valid embedded entitlement plist." >&2
    exit 1
  fi
  if ! fingerprint="$(python3 scripts/entitlement_fingerprint.py fingerprint "$entitlements")"; then
    rm -f "$entitlements"
    exit 1
  fi
  rm -f "$entitlements"
  if [[ "$fingerprint" != $'bool\tcom.apple.security.app-sandbox\ttrue' ]]; then
    echo "ERROR: SceneScript XPC service entitlements must be exactly App Sandbox." >&2
    printf '%s\n' "$fingerprint" >&2
    exit 1
  fi
}

echo "== Entitlement source baseline =="
scripts/check_entitlements.sh --sku pro --source
scripts/check_entitlements.sh --sku lite --source

echo "== Release build settings =="
xcodebuild -showBuildSettings \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -destination "$MACOS_DESTINATION" \
  | tee "$BUILD_SETTINGS_LOG" \
  | grep -E "PRODUCT_BUNDLE_IDENTIFIER|MARKETING_VERSION|CURRENT_PROJECT_VERSION|MACOSX_DEPLOYMENT_TARGET|ENABLE_HARDENED_RUNTIME|CODE_SIGN|DEVELOPMENT_TEAM|ENABLE_APP_SANDBOX|ENABLE_USER_SELECTED_FILES|ENTITLEMENTS"

if ! grep -q "ENABLE_HARDENED_RUNTIME = YES" "$BUILD_SETTINGS_LOG"; then
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

if ! security find-identity -p codesigning -v | grep -q '"Developer ID Application:'; then
  if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    echo "ERROR: No Developer ID Application signing identity found on this Mac." >&2
    exit 1
  fi
  echo "WARNING: No Developer ID Application signing identity found on this Mac; notarized export must run on a signing machine." >&2
fi

# App schemes omit SwiftPM test products, so package tests run explicitly first.
# Serial execution and isolated scratch paths avoid compiler-cache contention.
PACKAGE_TEST_PATHS=(
  "Packages/LiveWallpaperCore"
  "Packages/LiveWallpaperProWPE"
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
  -configuration Debug \
  -destination "$MACOS_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage NO \
  -only-testing:LiveWallpaperTests \
  SWIFT_EMIT_LOC_STRINGS=NO

# Cover Pro and Lite Debug/Release links with isolated build databases.
# Developer ID entitlements and notarization remain a separate signing-machine gate.
PRO_DEBUG_BIN="$DERIVED_DATA/Build/Products/Debug/LiveWallpaper.app/Contents/MacOS/LiveWallpaper"
[[ -x "$PRO_DEBUG_BIN" ]] || fail_with_log "Pro Debug test action did not produce the app binary."
assert_no_removed_dynamic_links "$PRO_DEBUG_BIN" "Pro Debug"

DERIVED_DATA_PRO_RELEASE="${DERIVED_DATA}ProRelease"
PRO_ARCHIVE_PATH="${PRO_ARCHIVE_PATH:-$DERIVED_DATA_PRO_RELEASE/LiveWallpaper-LinkMatrix.xcarchive}"
require_fresh_archive_path "$PRO_ARCHIVE_PATH" "Pro Release"
echo "== Link matrix + archive smoke: Pro Release =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -configuration Release \
  -destination "$MACOS_ARCHIVE_DESTINATION" \
  -archivePath "$PRO_ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PRO_RELEASE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  ARCHS=arm64 \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > "$MATRIX_BUILD_LOG" 2>&1 || fail_with_log "LiveWallpaper Release archive failed."
PRO_ARCHIVED_APP="$PRO_ARCHIVE_PATH/Products/Applications/LiveWallpaper.app"
PRO_RELEASE_BIN="$PRO_ARCHIVED_APP/Contents/MacOS/LiveWallpaper"
[[ -x "$PRO_RELEASE_BIN" ]] || fail_with_log "Pro Release archive did not produce LiveWallpaper.app."
assert_arm64_binary "$PRO_RELEASE_BIN" "Pro Release archive"
codesign --verify --deep --strict --verbose=2 "$PRO_ARCHIVED_APP"
assert_no_removed_dynamic_links "$PRO_RELEASE_BIN" "Pro Release archive"

PRO_XPC_SERVICE="$PRO_ARCHIVED_APP/Contents/XPCServices/SceneScriptXPCService.xpc"
[[ -d "$PRO_XPC_SERVICE" ]] || fail_with_log "Pro Release archive did not embed SceneScriptXPCService.xpc."
codesign --verify --strict --verbose=2 "$PRO_XPC_SERVICE"
assert_exact_xpc_sandbox_entitlements "$PRO_XPC_SERVICE"

DERIVED_DATA_LITE_DEBUG="${DERIVED_DATA}LiteDebug"
echo "== Link matrix: Lite Debug =="
xcodebuild build \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Debug \
  -destination "$MACOS_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_LITE_DEBUG" \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > "$MATRIX_BUILD_LOG" 2>&1 || fail_with_log "LiveWallpaperLite Debug build failed."
LITE_DEBUG_BIN="$DERIVED_DATA_LITE_DEBUG/Build/Products/Debug/Loomscreen.app/Contents/MacOS/Loomscreen"
[[ -x "$LITE_DEBUG_BIN" ]] || fail_with_log "Lite Debug build did not produce the app binary."
assert_no_removed_dynamic_links "$LITE_DEBUG_BIN" "Lite Debug"

DERIVED_DATA_LITE_RELEASE="${DERIVED_DATA}LiteRelease"
LITE_ARCHIVE_PATH="${LITE_ARCHIVE_PATH:-$DERIVED_DATA_LITE_RELEASE/Loomscreen-LinkMatrix.xcarchive}"
require_fresh_archive_path "$LITE_ARCHIVE_PATH" "Lite Release"
echo "== Link matrix + archive smoke: Lite Release =="
xcodebuild archive \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaperLite \
  -configuration Release \
  -destination "$MACOS_ARCHIVE_DESTINATION" \
  -archivePath "$LITE_ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_LITE_RELEASE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ENABLE_HARDENED_RUNTIME=YES \
  ARCHS=arm64 \
  SWIFT_EMIT_LOC_STRINGS=NO \
  > "$MATRIX_BUILD_LOG" 2>&1 || fail_with_log "LiveWallpaperLite Release archive failed."

LITE_ARCHIVED_APP="$LITE_ARCHIVE_PATH/Products/Applications/Loomscreen.app"
LITE_RELEASE_BIN="$LITE_ARCHIVED_APP/Contents/MacOS/Loomscreen"
[[ -x "$LITE_RELEASE_BIN" ]] || fail_with_log "Lite Release archive did not produce Loomscreen.app."
assert_arm64_binary "$LITE_RELEASE_BIN" "Lite Release archive"
codesign --verify --deep --strict --verbose=2 "$LITE_ARCHIVED_APP"
assert_no_removed_dynamic_links "$LITE_RELEASE_BIN" "Lite Release archive"

# Lite must remain free of Pro renderer and SceneScript components.
for lite_binary in "$LITE_DEBUG_BIN" "$LITE_RELEASE_BIN"; do
  if nm "$lite_binary" 2>/dev/null | grep -Eq 'WPEMetalSceneRenderer|WPEMetalRenderExecutor|WPESceneScriptXPC'; then
    echo "ERROR: Lite binary contains a Pro-only renderer/XPC symbol." >&2
    exit 1
  fi
  if otool -L "$lite_binary" | grep -q 'JavaScriptCore'; then
    echo "ERROR: Lite binary unexpectedly links JavaScriptCore." >&2
    exit 1
  fi
done
if [[ -d "$LITE_ARCHIVED_APP/Contents/XPCServices" ]]; then
  echo "ERROR: Lite Release archive unexpectedly embeds an XPC service." >&2
  exit 1
fi
echo "  ✓ Pro/Lite Debug/Release links, Pro XPC isolation, and Lite archive purity verified"

echo "== Diff whitespace check =="
git diff --check

echo "Release candidate checks passed."
