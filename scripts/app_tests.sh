#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage:
  scripts/app_tests.sh full [--without-building] [--slowest N] [--dry-run]
  scripts/app_tests.sh suites <Suite>... [--without-building] [--slowest N] [--dry-run]

Environment:
  DERIVED_DATA   Persistent build location (default: /tmp/LiveWallpaperAppTests)
  RESULT_BUNDLE  Fresh .xcresult path; defaults to a unique /tmp path
EOF
}

mode="${1:-}"
if [[ -z "$mode" || "$mode" == "-h" || "$mode" == "--help" ]]; then
  usage
  exit 0
fi
shift

case "$mode" in
  full|suites) ;;
  *)
    echo "ERROR: mode must be 'full' or 'suites'." >&2
    usage >&2
    exit 64
    ;;
esac

action="test"
slowest=10
dry_run=0
suites=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --without-building)
      action="test-without-building"
      shift
      ;;
    --slowest)
      [[ $# -ge 2 ]] || { echo "ERROR: --slowest requires a value." >&2; exit 64; }
      slowest="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "ERROR: unknown option '$1'." >&2
      exit 64
      ;;
    *)
      suites+=("$1")
      shift
      ;;
  esac
done

if [[ "$mode" == "full" && ${#suites[@]} -ne 0 ]]; then
  echo "ERROR: full mode does not accept suite names." >&2
  exit 64
fi
if [[ "$mode" == "suites" && ${#suites[@]} -eq 0 ]]; then
  echo "ERROR: suites mode requires at least one suite." >&2
  exit 64
fi
if ! [[ "$slowest" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --slowest must be a non-negative integer." >&2
  exit 64
fi

derived_data="${DERIVED_DATA:-/tmp/LiveWallpaperAppTests}"
result_bundle="${RESULT_BUNDLE:-/tmp/LiveWallpaperAppTests-${mode}-$(date +%Y%m%d-%H%M%S)-$$.xcresult}"
minimum_test_count=2400
label="LiveWallpaper full app tests"
selectors=()
required_suites=()

if [[ "$mode" == "suites" ]]; then
  minimum_test_count=1
  label="LiveWallpaper targeted suites"
  for suite in "${suites[@]}"; do
    selectors+=("-only-testing:LiveWallpaperTests/$suite")
    required_suites+=("--require-suite" "$suite")
  done
fi

command=(
  python3 scripts/xcode_test_runner.py
  --label "$label"
  --result-bundle "$result_bundle"
  --minimum-test-count "$minimum_test_count"
  --slowest "$slowest"
)
if [[ ${#required_suites[@]} -gt 0 ]]; then
  command+=("${required_suites[@]}")
fi
command+=(
  --
  -project LiveWallpaper.xcodeproj
  -scheme LiveWallpaper
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$derived_data"
  -enableCodeCoverage NO
)
if [[ ${#selectors[@]} -gt 0 ]]; then
  command+=("${selectors[@]}")
fi
command+=("$action" SWIFT_EMIT_LOC_STRINGS=NO)

if [[ "$dry_run" == "1" ]]; then
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

"${command[@]}"
