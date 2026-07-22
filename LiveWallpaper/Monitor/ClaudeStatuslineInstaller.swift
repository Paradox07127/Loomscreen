import Foundation

/// Produces the copy-paste snippets that let the Monitor read Claude Code's account rate limits.
enum ClaudeStatuslineInstaller {
    static let scriptFileName = "livewallpaper-statusline.sh"
    static let payloadFileName = ClaudeRateLimitReader.payloadFileName

    /// The capture script body written to `~/.claude/livewallpaper-statusline.sh`.
    static var captureScript: String {
        """
        #!/usr/bin/env bash
        # Installed by LiveWallpaper — extracts just the Claude Code account
        # rate-limit fields the Monitor reads into a file, then chains through to
        # your own statusline (if any). LiveWallpaper never edits this file; delete
        # it to uninstall.
        set -euo pipefail

        CLAUDE_DIR="${HOME}/.claude"
        OUT="${CLAUDE_DIR}/\(payloadFileName)"

        payload="$(cat)"

        # Whitelist only the rate-limit fields the app consumes; everything else in
        # the payload is discarded and never written to disk. Falls back to an empty
        # object if python3 is unavailable (the reader treats that as "no limits").
        limits="$(
          printf '%s' "${payload}" | /usr/bin/env python3 -c '
        import json, sys
        try:
            src = json.load(sys.stdin)
        except Exception:
            print("{}"); sys.exit(0)
        def pick(section):
            out = {}
            for k in ("used_percentage", "resets_at"):
                if isinstance(section, dict) and k in section:
                    out[k] = section[k]
            return out
        rl = src.get("rate_limits") if isinstance(src, dict) else None
        rl = rl if isinstance(rl, dict) else {}
        kept = {"rate_limits": {"five_hour": pick(rl.get("five_hour")), "seven_day": pick(rl.get("seven_day"))}}
        if isinstance(src, dict) and "timestamp" in src:
            kept["timestamp"] = src["timestamp"]
        print(json.dumps(kept))
        ' 2>/dev/null || printf '%s' '{}'
        )"

        # Atomic publish: write a sibling temp file, then rename over the target.
        tmp="$(mktemp "${CLAUDE_DIR}/.\(payloadFileName).XXXXXX")"
        printf '%s' "${limits}" > "${tmp}"
        mv -f "${tmp}" "${OUT}"

        # Chain through to a pre-existing statusline command, re-feeding the
        # ORIGINAL payload. The whole command arrives as ONE shell-quoted argument
        # and is run via `sh -c`, so pipes/args/env in the user's command survive.
        if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
          printf '%s' "${payload}" | exec /bin/sh -c "$1"
        fi

        # No chained command: emit a minimal statusline so something still shows.
        model="$(printf '%s' "${payload}" | /usr/bin/sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -n1)"
        [ -z "${model}" ] && model="Claude"
        printf '%s' "${model}"
        """
    }

    /// One-liner the user pastes into their terminal: writes the capture script, makes it executable, and prints guidance.
    static var installCommand: String {
        let heredoc = captureScript
        return """
        mkdir -p ~/.claude && cat > ~/.claude/\(scriptFileName) <<'LIVEWALLPAPER_EOF'
        \(heredoc)
        LIVEWALLPAPER_EOF
        chmod +x ~/.claude/\(scriptFileName) && echo 'Installed ~/.claude/\(scriptFileName). Next: merge the statusLine block from LiveWallpaper into ~/.claude/settings.json (pass your existing statusLine command as an argument to keep it working).'
        """
    }

    /// The exact JSON block the user should merge into `~/.claude/settings.json`.
    static func settingsFragment(existingCommand: String? = nil) -> String {
        let scriptPath = "$HOME/.claude/\(scriptFileName)"
        let command: String
        if let existing = existingCommand, !existing.trimmingCharacters(in: .whitespaces).isEmpty {
            command = "\(scriptPath) \(shellSingleQuoted(existing))"
        } else {
            command = scriptPath
        }
        return """
        {
          "statusLine": {
            "type": "command",
            "command": "\(escapeJSON(command))"
          }
        }
        """
    }

    /// Human note explaining the chaining decision, shown alongside the fragment.
    static func settingsGuidance(existingCommand: String?) -> String {
        if let existing = existingCommand, !existing.trimmingCharacters(in: .whitespaces).isEmpty {
            return String(
                localized: "You already have a statusLine command. It has been placed after the LiveWallpaper script above so it keeps running — merge this block into ~/.claude/settings.json.",
                defaultValue: "You already have a statusLine command. It has been placed after the LiveWallpaper script above so it keeps running — merge this block into ~/.claude/settings.json.",
                comment: "Monitor rate-limit setup: guidance when the user has an existing statusLine command."
            )
        }
        return String(
            localized: "Merge this block into ~/.claude/settings.json. If you later add your own statusLine command, append it after the script path so it chains through.",
            defaultValue: "Merge this block into ~/.claude/settings.json. If you later add your own statusLine command, append it after the script path so it chains through.",
            comment: "Monitor rate-limit setup: guidance when the user has no existing statusLine command."
        )
    }

    /// Removes the capture script.
    static var uninstallCommand: String {
        "rm -f ~/.claude/\(scriptFileName) ~/.claude/\(payloadFileName) && echo 'Removed the LiveWallpaper statusline script. If you set statusLine in ~/.claude/settings.json to it, restore your previous statusLine (or remove the block).'"
    }

    // MARK: - Escaping

    /// Minimal JSON string escaping for the command value embedded in the fragment (backslash and double-quote only; paths never contain controls).
    private static func shellSingleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
