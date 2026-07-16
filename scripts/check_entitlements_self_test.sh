#!/usr/bin/env bash
# Synthetic regression oracles for the shipped-app entitlement gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check_entitlements.sh"
HELPER="$ROOT/scripts/entitlement_fingerprint.py"
TMP="$(mktemp -d -t lw-entitlements-self-test.XXXXXX)"
OUTPUT="$TMP/output"
trap 'rm -rf "$TMP"' EXIT

PASS_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  ✓ $1"
}

expect_pass() {
  local label="$1"
  shift
  if ! "$@" >"$OUTPUT" 2>&1; then
    echo "SELF-TEST ERROR: expected pass: $label" >&2
    sed -n '1,80p' "$OUTPUT" >&2
    exit 1
  fi
  pass "$label"
}

expect_fail() {
  local label="$1" expected_text="$2"
  shift 2
  if "$@" >"$OUTPUT" 2>&1; then
    echo "SELF-TEST ERROR: expected failure: $label" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_text" "$OUTPUT"; then
    echo "SELF-TEST ERROR: '$label' failed for the wrong reason; expected: $expected_text" >&2
    sed -n '1,80p' "$OUTPUT" >&2
    exit 1
  fi
  pass "$label"
}

create_app() {
  local app="$1" bundle_id="$2" executable="$3"
  mkdir -p "$app/Contents/MacOS"
  cp /usr/bin/true "$app/Contents/MacOS/$executable"
  plutil -create xml1 "$app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string "$executable" "$app/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
}

sign_app() {
  local app="$1" entitlements="$2"
  codesign --force --sign - --entitlements "$entitlements" "$app" >/dev/null 2>&1
}

PRO_APP="$TMP/LiveWallpaper.app"
LITE_APP="$TMP/Loomscreen.app"
create_app "$PRO_APP" "Taijia.LiveWallpaper" "LiveWallpaper"
create_app "$LITE_APP" "com.loomscreen" "Loomscreen"

sign_app "$PRO_APP" "$ROOT/LiveWallpaper/LiveWallpaper.entitlements"
expect_pass "Pro ad-hoc app matches exact source baseline" \
  bash "$CHECKER" --sku pro --app "$PRO_APP"

cp "$ROOT/LiveWallpaper/LiveWallpaper.entitlements" "$TMP/adhoc-false.entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool false' "$TMP/adhoc-false.entitlements"
sign_app "$PRO_APP" "$TMP/adhoc-false.entitlements"
expect_pass "ad-hoc archive may carry explicit get-task-allow=false" \
  bash "$CHECKER" --sku pro --app "$PRO_APP"

sign_app "$LITE_APP" "$ROOT/LiveWallpaper/LiveWallpaperLite.entitlements"
expect_pass "Lite ad-hoc app matches exact source baseline" \
  bash "$CHECKER" --sku lite --app "$LITE_APP"

plutil -replace CFBundleIdentifier -string com.example.wrong-sku "$PRO_APP/Contents/Info.plist"
sign_app "$PRO_APP" "$ROOT/LiveWallpaper/LiveWallpaper.entitlements"
expect_fail "SKU is bound to its exact bundle identifier" "pro app must use bundle id" \
  bash "$CHECKER" --sku pro --app "$PRO_APP"
plutil -replace CFBundleIdentifier -string Taijia.LiveWallpaper "$PRO_APP/Contents/Info.plist"

cp "$ROOT/LiveWallpaper/LiveWallpaper.entitlements" "$TMP/multiline.entitlements"
/usr/libexec/PlistBuddy -c $'Set :com.apple.security.temporary-exception.sbpl:0 (allow process-info-listpids)\n(allow file-read* (subpath /private))' "$TMP/multiline.entitlements"
sign_app "$PRO_APP" "$TMP/multiline.entitlements"
expect_fail "multiline SBPL tail cannot hide behind an allowed first line" \
  'process-info-listpids)\n(allow file-read*' \
  bash "$CHECKER" --sku pro --app "$PRO_APP"

cp "$ROOT/LiveWallpaper/LiveWallpaper.entitlements" "$TMP/unknown.entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.example.unknown bool true' "$TMP/unknown.entitlements"
sign_app "$PRO_APP" "$TMP/unknown.entitlements"
expect_fail "unknown entitlement remains visible to the exact diff" "com.example.unknown" \
  bash "$CHECKER" --sku pro --app "$PRO_APP"

# A real TeamIdentifier comes from the signature, which an ad-hoc synthetic app
# cannot provide. Exercise the same structural policy entry point directly with
# a deterministic signed-identity fixture.
TEAM_ID="FWJP4B62U7"
APP_ID="$TEAM_ID.Taijia.LiveWallpaper"
IDENTITY_PLIST="$TMP/signed-identity.entitlements"
cp "$ROOT/LiveWallpaper/LiveWallpaper.entitlements" "$IDENTITY_PLIST"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_ID" "$IDENTITY_PLIST"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$IDENTITY_PLIST"
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$IDENTITY_PLIST"
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $APP_ID" "$IDENTITY_PLIST"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool false' "$IDENTITY_PLIST"

python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
  --bundle-id Taijia.LiveWallpaper \
  --expected-team-id "$TEAM_ID" \
  --team-id "$TEAM_ID" >"$TMP/identity.fingerprint"
expect_pass "exact signed identity metadata normalizes to the reviewed baseline" \
  diff -u "$ROOT/scripts/release-baselines/entitlements-pro.fingerprint" "$TMP/identity.fingerprint"

expect_fail "identity metadata is forbidden on an ad-hoc signature" "ad-hoc signature must not claim" \
  python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
    --bundle-id Taijia.LiveWallpaper --expected-team-id "$TEAM_ID"

expect_fail "code-signature team is pinned to the project team" "signed TeamIdentifier must be" \
  python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
    --bundle-id Taijia.LiveWallpaper --expected-team-id "$TEAM_ID" --team-id WRONGTEAM

/usr/libexec/PlistBuddy -c 'Set :com.apple.application-identifier FWJP4B62U7.com.example.wrong' "$IDENTITY_PLIST"
expect_fail "application identifier must bind TeamIdentifier and bundle id" \
  "com.apple.application-identifier must be" \
  python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
    --bundle-id Taijia.LiveWallpaper --expected-team-id "$TEAM_ID" --team-id "$TEAM_ID"
/usr/libexec/PlistBuddy -c "Set :com.apple.application-identifier $APP_ID" "$IDENTITY_PLIST"

/usr/libexec/PlistBuddy -c 'Set :com.apple.developer.team-identifier WRONGTEAM' "$IDENTITY_PLIST"
expect_fail "developer team entitlement must match the signature" \
  "must match signed TeamIdentifier" \
  python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
    --bundle-id Taijia.LiveWallpaper --expected-team-id "$TEAM_ID" --team-id "$TEAM_ID"
/usr/libexec/PlistBuddy -c "Set :com.apple.developer.team-identifier $TEAM_ID" "$IDENTITY_PLIST"

/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups:1 string FWJP4B62U7.shared' "$IDENTITY_PLIST"
expect_fail "unexpected keychain access group is rejected" "must be the exact default group" \
  python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
    --bundle-id Taijia.LiveWallpaper --expected-team-id "$TEAM_ID" --team-id "$TEAM_ID"
/usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups:1' "$IDENTITY_PLIST"

/usr/libexec/PlistBuddy -c 'Set :com.apple.security.get-task-allow true' "$IDENTITY_PLIST"
expect_fail "get-task-allow=true is forbidden for shipping apps" \
  "requires com.apple.security.get-task-allow=false" \
  python3 "$HELPER" app-fingerprint "$IDENTITY_PLIST" \
    --bundle-id Taijia.LiveWallpaper --expected-team-id "$TEAM_ID" --team-id "$TEAM_ID"

echo "Entitlement gate self-test passed: $PASS_COUNT synthetic policy cases."
