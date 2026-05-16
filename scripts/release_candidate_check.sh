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

echo "== Bookmark resolver audit =="
# Every security-scoped bookmark resolve should go through
# SecurityScopedBookmarkResolver (which observes bookmarkDataIsStale and
# persists the refresh). Bare URL(resolvingBookmarkData:) calls drop
# the stale flag and were the root cause of "user must re-grant after
# every restart" — see .claude/plan/settings-persistence-audit.md.
#
# Currently soft-warning while Phase 3 migrates the remaining 9 call
# sites. Once those are gone, drop the `|| true` and `>&2 ... continue`
# branch so this fails the build (tracked in Phase 6 of the plan).
BOOKMARK_OFFENDERS=$(
  rg -l 'resolvingBookmarkData' LiveWallpaper \
    --type swift \
    --glob '!LiveWallpaper/Infrastructure/SecurityScopedBookmarkResolver.swift' \
    --glob '!LiveWallpaper/ResourceUtilities.swift' \
  || true
)
if [[ -n "$BOOKMARK_OFFENDERS" ]]; then
  COUNT=$(echo "$BOOKMARK_OFFENDERS" | wc -l | tr -d ' ')
  echo "WARNING: $COUNT files still resolve bookmarks outside SecurityScopedBookmarkResolver:" >&2
  echo "$BOOKMARK_OFFENDERS" | sed 's/^/  - /' >&2
  echo "Migrate to SecurityScopedBookmarkResolver.shared.resolve(_:target:) — see .claude/plan/settings-persistence-audit.md." >&2
fi

echo "Release candidate checks passed."
