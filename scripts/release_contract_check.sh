#!/usr/bin/env bash
# Clean-clone-safe, non-building validation of the public release tooling.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

bash -n \
  scripts/release-app.sh \
  scripts/check_entitlements.sh \
  scripts/check_entitlements_self_test.sh \
  scripts/release_candidate_check.sh \
  scripts/fast_app_contract_tests.sh

bash scripts/release-app.sh --help >/dev/null
bash scripts/check_entitlements.sh --help >/dev/null
python3 scripts/entitlement_fingerprint.py --help >/dev/null
bash scripts/fast_app_contract_tests.sh --list >/dev/null
bash scripts/check_entitlements.sh --sku pro --source
bash scripts/check_entitlements.sh --sku lite --source
bash scripts/check_entitlements_self_test.sh

python3 scripts/check_quality_exclusions.py --self-test
python3 scripts/check_quality_exclusions.py
python3 scripts/check_module_import_boundaries.py --self-test
python3 scripts/check_module_import_boundaries.py

if grep -Eq 'codesign .*--entitlements|codesign .*--force.*--sign' scripts/release-app.sh; then
  echo "ERROR: release-app.sh must preserve Xcode's processed archive signature; raw entitlement re-signing is forbidden." >&2
  exit 1
fi
grep -q 'scripts/check_entitlements.sh --sku "$SKU" --app' scripts/release-app.sh
grep -q '<key>com.apple.security.app-sandbox</key>' LiveWallpaper/LiveWallpaper.entitlements
grep -q '<key>com.apple.security.app-sandbox</key>' LiveWallpaper/LiveWallpaperLite.entitlements

project_file="LiveWallpaper.xcodeproj/project.pbxproj"
[[ "$(grep -c 'CODE_SIGN_ENTITLEMENTS = LiveWallpaper/LiveWallpaper.entitlements;' "$project_file")" == "2" ]]
[[ "$(grep -c 'CODE_SIGN_ENTITLEMENTS = LiveWallpaper/LiveWallpaperLite.entitlements;' "$project_file")" == "2" ]]

# SceneScript hard isolation is a Pro-only embedded XPC release contract.
# The helper receives App Sandbox and no file/network entitlement of its own;
# Lite remains free of the target through the source-level contract suite.
xpc_entitlements="SceneScriptXPCService/SceneScriptXPCService.entitlements"
grep -q '<key>com.apple.security.app-sandbox</key>' "$xpc_entitlements"
[[ "$(grep -c '<key>' "$xpc_entitlements")" == "1" ]]
grep -Fq 'dstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices";' "$project_file"
grep -q 'SceneScriptXPCService.xpc' "$project_file"
[[ "$(grep -c 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;' "$project_file")" == "1" ]]

# Framework-subtraction leaves are release contracts, not one-time cleanup.
# Fail a clean clone if their package/product/config surfaces are reintroduced.
if git grep -n -E \
  'Sparkle\.framework|sparkle-project|SPUStandardUpdaterController|SPUUpdater|SUFeedURL|SUPublicEDKey|XCRemoteSwiftPackageReference.*Sparkle' \
  -- "$project_file" LiveWallpaperInfo.plist LoomscreenInfo.plist \
     LiveWallpaper/LiveWallpaper.entitlements LiveWallpaper/LiveWallpaperLite.entitlements \
     'Packages/*/Package.swift' ':(glob)**/Package.resolved' \
     scripts/release-app.sh scripts/release_candidate_check.sh .github/workflows; then
  echo "ERROR: removed Sparkle integration resurfaced in a live release surface." >&2
  exit 1
fi

if git grep -n -E \
  '^[[:space:]]*import[[:space:]]+Sparkle|SPUStandardUpdaterController|SPUUpdater' \
  -- LiveWallpaper LiveWallpaperTests; then
  echo "ERROR: removed Sparkle runtime API resurfaced in app source or tests." >&2
  exit 1
fi

if grep -Eq -- '(^|[ ="])-lc\+\+|CLANG_CXX_LIBRARY|c\+\+17|gnu\+\+17' "$project_file"; then
  echo "ERROR: removed manual libc++/target C++17 settings resurfaced." >&2
  exit 1
fi

if grep -q 'AppIntents' "$project_file"; then
  echo "ERROR: source-unused AppIntents framework link resurfaced." >&2
  exit 1
fi

lite_plan="$(bash scripts/release-app.sh --sku lite --version 0.0.0 --plan)"
pro_plan="$(bash scripts/release-app.sh --sku pro --version 0.0.0 --plan)"

grep -q '^scheme=LiveWallpaperLite$' <<<"$lite_plan"
grep -q '^app=Loomscreen.app$' <<<"$lite_plan"
grep -q '^bundle_id=com.loomscreen$' <<<"$lite_plan"
grep -q '^dmg=Loomscreen-0.0.0.dmg$' <<<"$lite_plan"
grep -q '^scheme=LiveWallpaper$' <<<"$pro_plan"
grep -q '^app=LiveWallpaper.app$' <<<"$pro_plan"
grep -q '^bundle_id=Taijia.LiveWallpaper$' <<<"$pro_plan"
grep -q '^dmg=Loomscreen-Pro-0.0.0.dmg$' <<<"$pro_plan"

echo "Release tooling contract passed for Lite and Pro."
