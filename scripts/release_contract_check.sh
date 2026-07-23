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
  scripts/release_contract_check.sh \
  scripts/app_tests.sh \
  scripts/fast_app_contract_tests.sh

bash scripts/release-app.sh --help >/dev/null
bash scripts/check_entitlements.sh --help >/dev/null
python3 scripts/entitlement_fingerprint.py --help >/dev/null
bash scripts/app_tests.sh --help >/dev/null
bash scripts/fast_app_contract_tests.sh --list >/dev/null
python3 scripts/xcode_test_runner_self_test.py
bash scripts/check_entitlements.sh --sku pro --source
bash scripts/check_entitlements.sh --sku lite --source
bash scripts/check_entitlements_self_test.sh

app_test_script="scripts/app_tests.sh"
grep -Fq 'scripts/app_tests.sh full' scripts/release_candidate_check.sh
grep -Fq 'minimum_test_count=2400' "$app_test_script"
grep -Fq -- '-only-testing:LiveWallpaperTests/$suite' "$app_test_script"
grep -Fq -- '-configuration Debug' "$app_test_script"
grep -Fq -- "-destination 'platform=macOS,arch=arm64'" "$app_test_script"
grep -Fq -- '-enableCodeCoverage NO' "$app_test_script"
grep -Fq 'SWIFT_EMIT_LOC_STRINGS=NO' "$app_test_script"
grep -Fq 'test-without-building' "$app_test_script"
full_test_command="$(scripts/app_tests.sh full --dry-run)"
targeted_test_command="$(scripts/app_tests.sh suites ContractProbeSuite --dry-run)"
grep -Fq -- ' test ' <<<"$full_test_command"
if grep -Fq -- '-only-testing:' <<<"$full_test_command"; then
  echo "ERROR: full app-test mode unexpectedly filters the test target." >&2
  exit 1
fi
grep -Fq -- '-only-testing:LiveWallpaperTests/ContractProbeSuite' <<<"$targeted_test_command"
grep -Fq -- '--require-suite ContractProbeSuite' <<<"$targeted_test_command"

candidate_script="scripts/release_candidate_check.sh"
grep -Fq 'MACOS_DESTINATION="platform=macOS,arch=arm64"' "$candidate_script"
grep -Fq 'MACOS_ARCHIVE_DESTINATION="generic/platform=macOS"' "$candidate_script"
grep -Fq -- "-destination 'platform=macOS,arch=arm64'" scripts/fast_app_contract_tests.sh
grep -Fq -- '-enableCodeCoverage NO' scripts/fast_app_contract_tests.sh
if grep -q 'CODE_SIGNING_ALLOWED=NO' "$candidate_script"; then
  echo "ERROR: release link/archive gates must exercise signing; CODE_SIGNING_ALLOWED=NO is forbidden." >&2
  exit 1
fi

pro_release_block="$(sed -n '/^echo "== Link matrix + archive smoke: Pro Release =="/,/^PRO_XPC_SERVICE=/p' "$candidate_script")"
lite_debug_block="$(sed -n '/^echo "== Link matrix: Lite Debug =="/,/^LITE_DEBUG_BIN=/p' "$candidate_script")"
lite_release_block="$(sed -n '/^echo "== Link matrix + archive smoke: Lite Release =="/,/^LITE_ARCHIVED_APP=/p' "$candidate_script")"

grep -q 'xcodebuild archive' <<<"$pro_release_block"
grep -q -- '-scheme LiveWallpaper' <<<"$pro_release_block"
grep -q -- '-configuration Release' <<<"$pro_release_block"
grep -q -- '-destination "$MACOS_ARCHIVE_DESTINATION"' <<<"$pro_release_block"
grep -q -- '-archivePath "$PRO_ARCHIVE_PATH"' <<<"$pro_release_block"
grep -q 'CODE_SIGN_IDENTITY="-"' <<<"$pro_release_block"
grep -q 'ARCHS=arm64' <<<"$pro_release_block"
grep -q 'SWIFT_EMIT_LOC_STRINGS=NO' <<<"$pro_release_block"
grep -Fq 'PRO_XPC_SERVICE="$PRO_ARCHIVED_APP/Contents/XPCServices/SceneScriptXPCService.xpc"' "$candidate_script"
grep -Fq 'codesign --verify --strict --verbose=2 "$PRO_XPC_SERVICE"' "$candidate_script"
grep -Fq 'assert_exact_xpc_sandbox_entitlements "$PRO_XPC_SERVICE"' "$candidate_script"
grep -Fq "SceneScript XPC service entitlements must be exactly App Sandbox." "$candidate_script"

grep -q 'xcodebuild build' <<<"$lite_debug_block"
grep -q -- '-scheme LiveWallpaperLite' <<<"$lite_debug_block"
grep -q -- '-configuration Debug' <<<"$lite_debug_block"
grep -q -- '-destination "$MACOS_DESTINATION"' <<<"$lite_debug_block"
grep -q 'SWIFT_EMIT_LOC_STRINGS=NO' <<<"$lite_debug_block"

grep -q 'xcodebuild archive' <<<"$lite_release_block"
grep -q -- '-scheme LiveWallpaperLite' <<<"$lite_release_block"
grep -q -- '-configuration Release' <<<"$lite_release_block"
grep -q -- '-destination "$MACOS_ARCHIVE_DESTINATION"' <<<"$lite_release_block"
grep -q -- '-archivePath "$LITE_ARCHIVE_PATH"' <<<"$lite_release_block"
grep -q 'CODE_SIGN_IDENTITY="-"' <<<"$lite_release_block"
grep -q 'ARCHS=arm64' <<<"$lite_release_block"
grep -q 'SWIFT_EMIT_LOC_STRINGS=NO' <<<"$lite_release_block"

for scheme_file in \
  LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaper.xcscheme \
  LiveWallpaper.xcodeproj/xcshareddata/xcschemes/LiveWallpaperLite.xcscheme; do
  grep -A2 '<ArchiveAction' "$scheme_file" | grep -q 'buildConfiguration = "Release"'
done

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

# The Pro-only SceneScript helper receives only the App Sandbox entitlement.
xpc_entitlements="SceneScriptXPCService/SceneScriptXPCService.entitlements"
grep -q '<key>com.apple.security.app-sandbox</key>' "$xpc_entitlements"
[[ "$(grep -c '<key>' "$xpc_entitlements")" == "1" ]]
grep -Fq 'dstPath = "$(CONTENTS_FOLDER_PATH)/XPCServices";' "$project_file"
grep -q 'SceneScriptXPCService.xpc' "$project_file"
[[ "$(grep -c 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO;' "$project_file")" == "1" ]]

# Prevent removed dependencies from returning to release surfaces.
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
