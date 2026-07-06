import Testing
import Foundation
@testable import LiveWallpaper

@Suite("Claude statusline installer snippets")
struct ClaudeStatuslineInstallerTests {

    @Test("Capture script writes atomically via mktemp + mv")
    func atomicWritePattern() {
        let script = ClaudeStatuslineInstaller.captureScript
        #expect(script.contains("mktemp"))
        #expect(script.contains("mv -f"))
        // The temp file must be renamed onto the exact payload the reader reads.
        #expect(script.contains(ClaudeRateLimitReader.payloadFileName))
    }

    @Test("Capture script reads stdin once and chains through when given a command")
    func chainThroughBranch() {
        let script = ClaudeStatuslineInstaller.captureScript
        #expect(script.contains("payload=\"$(cat)\""))
        // Chain branch: the user's whole command travels as ONE quoted argument
        // and is re-fed the payload via `sh -c`, so pipes/args survive.
        #expect(script.contains("exec /bin/sh -c \"$1\""))
        #expect(script.contains("[ \"$#\" -ge 1 ]"))
    }

    @Test("Capture script prints a minimal fallback statusline")
    func minimalFallbackLine() {
        let script = ClaudeStatuslineInstaller.captureScript
        // Falls back to the model display name so the statusline still shows.
        #expect(script.contains("display_name"))
        #expect(script.contains("printf '%s' \"${model}\""))
    }

    @Test("Install one-liner writes + chmods the script and does not edit settings")
    func installCommandShape() {
        let install = ClaudeStatuslineInstaller.installCommand
        #expect(install.contains(ClaudeStatuslineInstaller.scriptFileName))
        #expect(install.contains("chmod +x"))
        assertNoSettingsAutoEdit(install)
    }

    @Test("Settings fragment is valid mergeable JSON with a command statusLine")
    func settingsFragmentIsJSON() throws {
        let fragment = ClaudeStatuslineInstaller.settingsFragment(existingCommand: nil)
        let data = try #require(fragment.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let statusLine = try #require(object?["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        let command = try #require(statusLine["command"] as? String)
        #expect(command.contains(ClaudeStatuslineInstaller.scriptFileName))
    }

    @Test("Existing statusLine command becomes the chain argument")
    func fragmentChainsExistingCommand() throws {
        let existing = "~/bin/my-statusline.sh --fancy"
        let fragment = ClaudeStatuslineInstaller.settingsFragment(existingCommand: existing)
        let data = try #require(fragment.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let statusLine = try #require(object?["statusLine"] as? [String: Any])
        let command = try #require(statusLine["command"] as? String)
        // Our script runs first; the user's command trails as ONE single-quoted
        // argument (the capture script `sh -c`s it).
        #expect(command.contains(ClaudeStatuslineInstaller.scriptFileName))
        #expect(command.contains(existing))
        #expect(command.hasSuffix("'\(existing)'"))
    }

    @Test("Empty existing command yields a bare script-path command")
    func fragmentEmptyExisting() throws {
        let fragment = ClaudeStatuslineInstaller.settingsFragment(existingCommand: "   ")
        let data = try #require(fragment.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let statusLine = try #require(object?["statusLine"] as? [String: Any])
        let command = try #require(statusLine["command"] as? String)
        #expect(command.hasSuffix(ClaudeStatuslineInstaller.scriptFileName))
    }

    @Test("Uninstall snippet removes the script and never edits settings")
    func uninstallSnippetShape() {
        let uninstall = ClaudeStatuslineInstaller.uninstallCommand
        #expect(uninstall.contains("rm -f"))
        #expect(uninstall.contains(ClaudeStatuslineInstaller.scriptFileName))
        assertNoSettingsAutoEdit(uninstall)
    }

    @Test("No generated snippet auto-edits settings.json")
    func nothingAutoEditsSettings() {
        assertNoSettingsAutoEdit(ClaudeStatuslineInstaller.captureScript)
        assertNoSettingsAutoEdit(ClaudeStatuslineInstaller.installCommand)
        assertNoSettingsAutoEdit(ClaudeStatuslineInstaller.uninstallCommand)
        // The fragment MENTIONS settings.json (it's the thing to merge) but must
        // not be a shell write to it; guard on the write verbs only.
        assertNoSettingsWrite(ClaudeStatuslineInstaller.captureScript)
        assertNoSettingsWrite(ClaudeStatuslineInstaller.installCommand)
        assertNoSettingsWrite(ClaudeStatuslineInstaller.uninstallCommand)
    }

    // MARK: - Helpers

    /// Fails if a runnable snippet redirects/pipes into settings.json.
    private func assertNoSettingsWrite(_ snippet: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let forbidden = ["> ~/.claude/settings.json", ">~/.claude/settings.json",
                         "> $HOME/.claude/settings.json", "tee ~/.claude/settings.json",
                         "settings.json <<"]
        for pattern in forbidden {
            #expect(!snippet.contains(pattern), "snippet writes settings.json via \(pattern)", sourceLocation: sourceLocation)
        }
    }

    /// Stronger guard for snippets that shouldn't reference settings.json edits
    /// at all beyond guidance text (install/uninstall echo guidance only).
    private func assertNoSettingsAutoEdit(_ snippet: String, sourceLocation: SourceLocation = #_sourceLocation) {
        assertNoSettingsWrite(snippet, sourceLocation: sourceLocation)
        // No in-place editors pointed at settings.json either.
        for editor in ["sed -i", "jq"] where snippet.contains(editor) {
            #expect(!snippet.contains("settings.json"), "snippet uses \(editor) on settings.json", sourceLocation: sourceLocation)
        }
    }
}
