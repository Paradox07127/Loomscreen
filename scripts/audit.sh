#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/LiveWallpaper.xcodeproj"
SCHEME="${SCHEME:-LiveWallpaper}"
DESTINATION="${DESTINATION:-platform=macOS}"
AUDIT_DIR="${AUDIT_DIR:-$ROOT/.audit}"

mkdir -p "$AUDIT_DIR"

usage() {
  cat <<'USAGE'
Usage: scripts/audit.sh [phase]

Phases:
  baseline   xcodebuild build, test, and analyze
  static     grep risk patterns and long comment blocks
  leaks      launch with a temporary HOME and run leaks
  perf       launch with a temporary HOME and capture sample/vmmap
  all        baseline + static + leaks

Environment:
  SCHEME=LiveWallpaper
  DESTINATION='platform=macOS'
  AUDIT_DIR=.audit
  LIVEWALLPAPER_USE_REAL_HOME=1   use your real app preferences for leaks/perf
USAGE
}

build_app() {
  xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" | tee "$AUDIT_DIR/build.log"
}

test_app() {
  xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" | tee "$AUDIT_DIR/test.log"
}

analyze_app() {
  xcodebuild analyze -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" | tee "$AUDIT_DIR/analyze.log"
}

app_path() {
  xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" \
    | awk -F' = ' '
      /TARGET_BUILD_DIR =/ { dir=$2 }
      /FULL_PRODUCT_NAME =/ { name=$2 }
      END {
        if (dir == "" || name == "") exit 1
        print dir "/" name
      }
    '
}

run_with_optional_temp_home() {
  local app="$1"
  local seconds="$2"
  local tmp_home=""

  if [[ "${LIVEWALLPAPER_USE_REAL_HOME:-0}" == "1" ]]; then
    "$app/Contents/MacOS/LiveWallpaper" >"$AUDIT_DIR/runtime.log" 2>&1 &
  else
    tmp_home="$(mktemp -d /tmp/livewallpaper-audit-home.XXXXXX)"
    HOME="$tmp_home" CFFIXED_USER_HOME="$tmp_home" "$app/Contents/MacOS/LiveWallpaper" >"$AUDIT_DIR/runtime.log" 2>&1 &
  fi

  local pid=$!
  sleep "$seconds"

  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$AUDIT_DIR/runtime.log"
    [[ -n "$tmp_home" ]] && rm -rf "$tmp_home"
    return 1
  fi

  echo "$pid:$tmp_home"
}

cleanup_pid_home() {
  local pid="$1"
  local tmp_home="$2"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [[ -n "$tmp_home" ]] && rm -rf "$tmp_home"
}

baseline_phase() {
  build_app
  test_app
  analyze_app
}

static_phase() {
  rg -n "TODO|FIXME|HACK|fatalError|try!|as!|unowned|Timer|addObserver|Task\\s*\\{|Task\\.detached|WKWebView|AVPlayer|NSWindow|startAccessingSecurityScopedResource|Data\\(|String\\(contentsOf" \
    "$ROOT/LiveWallpaper" "$ROOT/LiveWallpaperTests" \
    >"$AUDIT_DIR/risk-grep.txt" || true

  local insecure_secure_coding="$AUDIT_DIR/insecure-secure-coding.txt"
  rg -n "NSKeyedUnarchiver.*NSObject|unarchivedObject\\(ofClasses:.*NSObject|allowedClasses:.*NSObject|decodeObject\\(of:.*NSObject|decodeObject\\(ofClasses:.*NSObject" \
    "$ROOT/LiveWallpaper" "$ROOT/LiveWallpaperTests" \
    >"$insecure_secure_coding" || true
  if [[ -s "$insecure_secure_coding" ]]; then
    echo "ERROR: Insecure NSSecureCoding allow-list found. Do not allow NSObject during secure decode." >&2
    cat "$insecure_secure_coding" >&2
    exit 1
  fi

  awk '
    FNR==1 {
      if (block>4) print file ":" start "-" (FNR-1) " " block
      file=FILENAME; block=0; start=0
    }
    /^[[:space:]]*\/\/\/|^[[:space:]]*\/\// {
      if (block==0) start=FNR
      block++
      next
    }
    {
      if (block>4) print file ":" start "-" (FNR-1) " " block
      block=0; start=0
    }
    END {
      if (block>4) print file ":" start "-" FNR " " block
    }
  ' $(rg --files -g '*.swift' "$ROOT/LiveWallpaper" "$ROOT/LiveWallpaperTests") \
    >"$AUDIT_DIR/long-comments.txt"

  wc -l "$AUDIT_DIR/risk-grep.txt" "$AUDIT_DIR/long-comments.txt" "$insecure_secure_coding"
}

leaks_phase() {
  build_app
  local app
  app="$(app_path)"
  local result
  result="$(run_with_optional_temp_home "$app" 8)"
  local pid="${result%%:*}"
  local tmp_home="${result#*:}"
  leaks "$pid" >"$AUDIT_DIR/leaks.txt" 2>&1 || true
  tail -n 80 "$AUDIT_DIR/leaks.txt"
  cleanup_pid_home "$pid" "$tmp_home"
}

perf_phase() {
  build_app
  local app
  app="$(app_path)"
  local result
  result="$(run_with_optional_temp_home "$app" 8)"
  local pid="${result%%:*}"
  local tmp_home="${result#*:}"
  sample "$pid" 5 1 -file "$AUDIT_DIR/sample.txt" >/dev/null 2>&1 || true
  vmmap "$pid" >"$AUDIT_DIR/vmmap.txt" 2>&1 || true
  cleanup_pid_home "$pid" "$tmp_home"
  ls -lh "$AUDIT_DIR/sample.txt" "$AUDIT_DIR/vmmap.txt"
}

phase="${1:-all}"
case "$phase" in
  baseline) baseline_phase ;;
  static) static_phase ;;
  leaks) leaks_phase ;;
  perf) perf_phase ;;
  all) baseline_phase; static_phase; leaks_phase ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
