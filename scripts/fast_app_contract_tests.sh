#!/usr/bin/env bash
# Hardware-free app architecture/security shard for required PR validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-/tmp/LiveWallpaperFastAppContracts}"
RESULT_BUNDLE="${RESULT_BUNDLE:-/tmp/LiveWallpaperFastAppContracts-$$.xcresult}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

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
  RR03RendererLivenessLockTests
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
  WPESceneScriptXPCCorpusParityTests
  WPESceneScriptXPCContractTests
  WPEUploadCancellationOracleTests
  WorkshopInstalledOwnershipCharacterizationTests
)

case "${1:-}" in
  "") ;;
  --list)
    printf '%s\n' "${SUITES[@]}"
    exit 0
    ;;
  -h|--help)
    sed -n '2,8p' "$0"
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
xcodebuild test \
  -project LiveWallpaper.xcodeproj \
  -scheme LiveWallpaper \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  "${only_testing[@]}" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  SWIFT_EMIT_LOC_STRINGS=NO

# xcodebuild treats an unknown -only-testing suite as a successful zero-test
# selection. Assert each requested Swift Testing suite actually appears in the
# xcresult so a rename/removal cannot silently weaken the required PR gate.
RESULT_JSON="${RESULT_BUNDLE%.xcresult}.json"
xcrun xcresulttool get test-results tests \
  --path "$RESULT_BUNDLE" \
  --format json \
  > "$RESULT_JSON"

missing_suites=()
for suite in "${SUITES[@]}"; do
  if ! grep -Fq "/${suite}\"" "$RESULT_JSON"; then
    missing_suites+=("$suite")
  fi
done
if [[ ${#missing_suites[@]} -ne 0 ]]; then
  echo "ERROR: requested suites absent from xcresult: ${missing_suites[*]}" >&2
  exit 1
fi

echo "Verified all ${#SUITES[@]} requested suites in $RESULT_BUNDLE"
