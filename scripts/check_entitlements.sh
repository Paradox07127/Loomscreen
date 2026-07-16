#!/usr/bin/env bash
#
# Entitlement drift guard. Fingerprints each entitlement with its key, value
# type and value, then fails on any difference from the reviewed baseline.
# Keeping the association matters: a flat key/string multiset can report green
# after a value moves under a wider key or a required boolean disappears.
#
# Usage:
#   scripts/check_entitlements.sh --sku pro  --source
#   scripts/check_entitlements.sh --sku lite --app <path.app>
#   scripts/check_entitlements.sh --sku pro  --update-baseline
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIFF_FILE="$(mktemp -t lw-entitlements-diff.XXXXXX)"
trap 'rm -f "$DIFF_FILE"' EXIT

# Sorted, key-associated typed lines produced by a structural plist parser.
# XML is deliberately not parsed with awk: SBPL strings can contain newlines,
# and truncating a continued value can hide a sandbox expansion.
fingerprint_plist() {
  python3 "$ROOT/scripts/entitlement_fingerprint.py" fingerprint "$1"
}

fingerprint_app() {
  local app="$1" bundle_id="$2" expected_team_id="$3" tmp signing_info team_id fingerprint
  tmp="$(mktemp -t lw-entitlements.XXXXXX)"
  if ! codesign -d --entitlements - --xml "$app" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "ERROR: could not read entitlements from $app" >&2
    return 2
  fi
  if [[ ! -s "$tmp" ]] || ! plutil -lint "$tmp" >/dev/null; then
    rm -f "$tmp"
    echo "ERROR: $app has no valid embedded entitlement plist" >&2
    return 2
  fi
  if ! signing_info="$(codesign -d --verbose=4 "$app" 2>&1)"; then
    rm -f "$tmp"
    echo "ERROR: could not read signing identity from $app" >&2
    return 2
  fi
  team_id="$(printf '%s\n' "$signing_info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if [[ "$team_id" == "not set" ]]; then
    team_id=""
  fi
  # Xcode may synthesize identity metadata for Developer-signed/profiled apps.
  # The helper removes a field only after proving it is exactly derived from the
  # real code-signature TeamIdentifier and CFBundleIdentifier. Unknown fields
  # remain in the fingerprint and therefore make the exact baseline diff red.
  if [[ -n "$team_id" ]]; then
    if ! fingerprint="$(python3 "$ROOT/scripts/entitlement_fingerprint.py" app-fingerprint "$tmp" \
      --bundle-id "$bundle_id" \
      --expected-team-id "$expected_team_id" \
      --team-id "$team_id")"; then
      rm -f "$tmp"
      return 1
    fi
  else
    if ! fingerprint="$(python3 "$ROOT/scripts/entitlement_fingerprint.py" app-fingerprint "$tmp" \
      --bundle-id "$bundle_id" \
      --expected-team-id "$expected_team_id")"; then
      rm -f "$tmp"
      return 1
    fi
  fi
  rm -f "$tmp"
  printf '%s\n' "$fingerprint"
}

MODE="source"
SKU=""
APP_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sku)             SKU="${2:?--sku needs pro or lite}"; shift 2 ;;
    --source)          MODE="source"; shift ;;
    --app)             MODE="app"; APP_PATH="${2:?--app needs a .app path}"; shift 2 ;;
    --update-baseline) MODE="update"; shift ;;
    -h|--help)         sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 64 ;;
  esac
done

case "$SKU" in
  pro)
    SOURCE_ENTITLEMENTS="$ROOT/LiveWallpaper/LiveWallpaper.entitlements"
    BASELINE="$ROOT/scripts/release-baselines/entitlements-pro.fingerprint"
    EXPECTED_BUNDLE_ID="Taijia.LiveWallpaper"
    EXPECTED_TEAM_ID="FWJP4B62U7"
    ;;
  lite)
    SOURCE_ENTITLEMENTS="$ROOT/LiveWallpaper/LiveWallpaperLite.entitlements"
    BASELINE="$ROOT/scripts/release-baselines/entitlements-lite.fingerprint"
    EXPECTED_BUNDLE_ID="com.loomscreen"
    EXPECTED_TEAM_ID="FWJP4B62U7"
    ;;
  *)
    echo "ERROR: --sku must be 'pro' or 'lite' (got: ${SKU:-<missing>})" >&2
    exit 64
    ;;
esac

if [[ ! -f "$SOURCE_ENTITLEMENTS" ]]; then
  echo "ERROR: entitlements file missing: $SOURCE_ENTITLEMENTS" >&2
  exit 1
fi

mkdir -p "$(dirname "$BASELINE")"

if [[ "$MODE" == "update" ]]; then
  fingerprint_plist "$SOURCE_ENTITLEMENTS" >"$BASELINE"
  echo "Updated $SKU entitlement baseline ($(grep -c . "$BASELINE") lines): $BASELINE"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "ERROR: no entitlement baseline at $BASELINE." >&2
  echo "       Review the $SKU entitlements, then create it once:" >&2
  echo "         scripts/check_entitlements.sh --sku $SKU --update-baseline" >&2
  exit 1
fi

case "$MODE" in
  source)
    ACTUAL="$(fingerprint_plist "$SOURCE_ENTITLEMENTS")"
    EXPECTED="$(cat "$BASELINE")"
    LABEL="tracked $SKU entitlements"
    ;;
  app)
    if [[ ! -d "$APP_PATH" || "$APP_PATH" != *.app ]]; then
      echo "ERROR: --app must name an existing .app bundle: $APP_PATH" >&2
      exit 64
    fi
    if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
      echo "ERROR: app is missing Contents/Info.plist: $APP_PATH" >&2
      exit 64
    fi
    if ! BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_PATH/Contents/Info.plist" 2>/dev/null)"; then
      echo "ERROR: app has no valid CFBundleIdentifier: $APP_PATH" >&2
      exit 64
    fi
    if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
      echo "ERROR: $SKU app must use bundle id $EXPECTED_BUNDLE_ID, got $BUNDLE_ID" >&2
      exit 1
    fi
    ACTUAL="$(fingerprint_app "$APP_PATH" "$BUNDLE_ID" "$EXPECTED_TEAM_ID")"
    EXPECTED="$(cat "$BASELINE")"
    LABEL="$APP_PATH"
    ;;
esac

if ! diff -u <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL") >"$DIFF_FILE"; then
  echo "ERROR: entitlements of $LABEL differ from the reviewed baseline:" >&2
  sed -n '3,$p' "$DIFF_FILE" >&2
  echo "" >&2
  echo "       An added key or path/mach-lookup exception widens the sandbox." >&2
  echo "       If this change is intended, review it, then regenerate:" >&2
  echo "         scripts/check_entitlements.sh --sku $SKU --update-baseline" >&2
  exit 1
fi

echo "  ✓ entitlements match baseline ($LABEL)"
