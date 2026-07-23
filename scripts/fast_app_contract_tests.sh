#!/usr/bin/env bash
# Hardware-free app architecture/security shard for required PR validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperFastAppContracts}"
RESULT_BUNDLE="${RESULT_BUNDLE:-/tmp/LiveWallpaperFastAppContracts-$$.xcresult}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

usage() {
  cat <<'EOF'
Usage: scripts/fast_app_contract_tests.sh [--without-building|--list]

Runs the hardware-free architecture/security suites with concise xcresult
reporting. --without-building reuses products in DERIVED_DATA.
EOF
}

SUITES=(
  GeneralSettingsOwnershipCharacterizationTests
  InfrastructureRuntimeBoundaryTests
  ModuleImportBoundaryTests
  EntitlementAuditTests
  HTMLTrustVerdictTests
  LogPrivacySourceAuditTests
  LocalizationCoverageTests
  MonitorBoardPlacementAccessibilityCharacterizationTests
  MonitorOverlayVisibilityLifecycleCharacterizationTests
  MonitorRuntimeLeaseChurnCharacterizationTests
  MonitorSamplerOwnershipCharacterizationTests
  MonitorSuspendEnergyTests
  MonitorUsagePresentationCharacterizationTests
  PIISanitizerTests
  RepositoryRootTests
  SchemeEnvironmentContractTests
  SecurityScopedBookmarkResolverTests
  SteamCMDDoctorBoundaryCharacterizationTests
  SteamCMDDoctorLifecycleTests
  SystemMemoryPressureWatcherTests
  VideoResolutionContractCharacterizationTests
  WPECorpusManifestTests
  WPERendererOwnershipCharacterizationTests
  WPESceneScriptB2bResourceLimitTests
  WPESceneScriptContainmentCharacterizationTests
  WPEUploadCancellationOracleTests
  WorkshopInstalledOwnershipCharacterizationTests
)

action="test"
case "${1:-}" in
  "") ;;
  --without-building)
    action="test-without-building"
    ;;
  --list)
    printf '%s\n' "${SUITES[@]}"
    exit 0
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown argument '$1'" >&2
    exit 64
    ;;
esac

only_testing=()
for suite in "${SUITES[@]}"; do
  only_testing+=("-only-testing:LiveWallpaperTests/$suite")
done

echo "== Fast app architecture/security contracts (${#SUITES[@]} suites) =="
required_suites=()
for suite in "${SUITES[@]}"; do
  required_suites+=("--require-suite" "$suite")
done

python3 scripts/xcode_test_runner.py \
  --label "Fast app architecture/security contracts" \
  --result-bundle "$RESULT_BUNDLE" \
  --minimum-test-count 1 \
  --slowest 10 \
  "${required_suites[@]}" \
  -- \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  "${only_testing[@]}" \
  "$action" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  SWIFT_EMIT_LOC_STRINGS=NO
