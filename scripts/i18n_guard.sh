#!/usr/bin/env bash
# i18n regression guard for LiveWallpaper.
#
# Modes:
#   scripts/i18n_guard.sh                       # default: scan staged Swift files
#   I18N_GUARD_SCOPE=all scripts/i18n_guard.sh  # whole-app scan (CI / manual)
#
# Xcode Run Script Build Phase:
#   I18N_GUARD_SCOPE=all "$SRCROOT/scripts/i18n_guard.sh"
#
# Escape hatch: append `// i18n:ignore` on the same line for deliberate non-user-facing literals.

set -euo pipefail

ROOT="${SRCROOT:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(git rev-parse --show-toplevel)"
fi

APP="$ROOT/LiveWallpaper"
RG="${RG:-rg}"
SCOPE="${I18N_GUARD_SCOPE:-staged}"
fail=0

if ! command -v "$RG" >/dev/null 2>&1; then
  echo "[i18n] ripgrep is required. Install it with: brew install ripgrep" >&2
  exit 127
fi

collect_files() {
  case "$SCOPE" in
    all)
      "$RG" --files "$APP" -g '*.swift'
      ;;
    staged)
      git -C "$ROOT" diff --cached --name-only --diff-filter=ACMR \
        | "$RG" '^LiveWallpaper/.*\.swift$' \
        | sed "s#^#$ROOT/#" || true
      ;;
    *)
      echo "[i18n] Unsupported I18N_GUARD_SCOPE=$SCOPE. Use staged or all." >&2
      exit 2
      ;;
  esac
}

swift_files=()
while IFS= read -r line; do
  [[ -n "$line" ]] && swift_files+=("$line")
done < <(collect_files)

if [[ "${#swift_files[@]}" -eq 0 ]]; then
  exit 0
fi

report_matches() {
  local title="$1"
  local pattern="$2"
  local matches

  matches="$("$RG" -n --pcre2 "$pattern" "${swift_files[@]}" | "$RG" -v 'i18n:ignore' || true)"
  if [[ -n "$matches" ]]; then
    printf '\n[i18n] %s\n%s\n' "$title" "$matches"
    fail=1
  fi
}

report_multiline_matches() {
  local title="$1"
  local pattern="$2"
  local matches

  matches="$("$RG" -nU --pcre2 "$pattern" "${swift_files[@]}" | "$RG" -v 'i18n:ignore' || true)"
  if [[ -n "$matches" ]]; then
    printf '\n[i18n] %s\n%s\n' "$title" "$matches"
    fail=1
  fi
}

report_matches \
  'Use Text("...") instead of literal SwiftUI accessibility/help strings.' \
  '^\s*\.(accessibilityLabel|accessibilityHint|accessibilityValue|help)\(\s*"[^"]+'

report_matches \
  'Wrap ternary accessibility/help branches in Text() so both arms are localizable.' \
  '^\s*\.(accessibilityLabel|accessibilityHint|accessibilityValue|help)\(\s*(?!Text\()[^()]*\?\s*"[^"]+"\s*:\s*"'

report_matches \
  'Do not render enum rawValue/description/label directly; expose a LocalizedStringKey/Text/String(localized:) display API.' \
  '^\s*(Text|Label)\(\s*(?!verbatim:)[^\n]*(\.(rawValue|description|label)\b)'

report_matches \
  'Do not interpolate enum rawValue/description/label into accessibility/help copy.' \
  '^\s*\.(accessibilityLabel|accessibilityHint|accessibilityValue|help)\([^\n]*(\.(rawValue|description|label)\b)'

report_matches \
  'Use L10n.Panel instead of literal NSOpenPanel prompt/message/title strings.' \
  '^\s*panel\.(prompt|message|title)\s*=\s*"[^"]+'

report_matches \
  'Use L10n.Window instead of literal NSWindow title strings.' \
  '^\s*window\.title\s*=\s*"[^"]+'

report_matches \
  'Use String(localized:) for AppKit NSMenuItem/NSAlert titles.' \
  '^\s*(NSMenuItem|NSAlert)\([^)]*title:\s*"[^"]+'

report_multiline_matches \
  'Use String(localized:defaultValue:comment:) inside LocalizedError.errorDescription / recoverySuggestion.' \
  '(?s)var\s+(errorDescription|recoverySuggestion)\s*:\s*String\??\s*\{(?:(?!\n    \}).)*\breturn\s+"[^"]+'

if [[ "$fail" -ne 0 ]]; then
  cat >&2 <<'EOF'

[i18n] Hard-coded user-facing strings were found.
[i18n] Replace them with Text(...) wrappers, L10n.* constants, or String(localized:defaultValue:comment:).
[i18n] For deliberate non-user-facing literals (Logger output, NotificationName, UserDefaults keys, etc.), add // i18n:ignore on the same line.

Key buckets:
  panel.prompt.* / panel.message.*
  window.title.*
  error.app.* / error.scene.* / error.render.* / error.texture.*

Use snake_case key segments and explicit keys to avoid collisions with natural-language SwiftUI keys.
EOF
  exit 1
fi
