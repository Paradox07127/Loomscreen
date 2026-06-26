#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import Foundation

/// JSON shape copied to clipboard when the user clicks "Copy diagnostic"
/// on a Workshop error state.
///
/// Contract: documented in
/// `docs/2026-05-28-steam-workshop-integration-plan.md` ("Diagnostic
/// export"). Every red / yellow UI state must produce a non-empty payload;
/// missing fields are emitted as `null` so the user can paste it into a
/// GitHub issue without further editing.
struct WorkshopDiagnosticPayload: Codable, Equatable, Sendable {
    let phase: Phase
    let ts: String
    let regexMatch: String?
    let tail: String
    let appVersion: String
    let macos: String
    let arch: String

    enum Phase: String, Codable, Equatable, Sendable {
        case metadata
        case doctor
        case download
        case `import`
        case search
    }

    init(
        phase: Phase,
        regexMatch: String?,
        tail: String,
        timestamp: Date = Date(),
        appVersion: String = WorkshopDiagnosticPayload.runningAppVersion,
        macOSVersion: String = WorkshopDiagnosticPayload.runningMacOSVersion,
        architecture: String = WorkshopDiagnosticPayload.runningArchitecture
    ) {
        self.phase = phase
        self.regexMatch = regexMatch
        self.tail = WorkshopDiagnosticRedactor.redact(tail)
        self.appVersion = appVersion
        self.macos = macOSVersion
        self.arch = architecture
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.ts = formatter.string(from: timestamp)
    }

    private enum CodingKeys: String, CodingKey {
        case phase
        case ts
        case regexMatch = "regex_match"
        case tail
        case appVersion = "app_version"
        case macos
        case arch
    }

    /// Pretty-printed because the user pastes this into a GitHub issue —
    /// readability beats minimum bytes.
    func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Returns `true` on success — callers surface the toast only when the copy
    /// actually happened so a clipboard-permission denial doesn't lie to the user.
    @MainActor
    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(encodedJSON(), forType: .string)
    }

    // MARK: - Static helpers

    static let runningAppVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }()

    static let runningMacOSVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    static let runningArchitecture: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()
}

/// Redacts secrets and personal-identifying values from any text we are
/// about to surface to the user or write to disk.
enum WorkshopDiagnosticRedactor {

    static func redact(_ raw: String) -> String {
        var output = raw

        // Steam Web API key: 32-hex value. Steam mixes upper- and lowercase
        // in different surfaces, so match case-insensitively. Word-bounded
        // to avoid matching unrelated 32-hex strings inside longer hashes.
        output = output.replacingOccurrences(
            of: #"(?i)\bkey=[a-f0-9]{32}\b"#,
            with: "key=<redacted>",
            options: .regularExpression
        )

        // 17-digit SteamID64 (`7656119` prefix + 10 digits).
        output = output.replacingOccurrences(of: #"\b7656119\d{10}\b"#, with: "<steamid>", options: .regularExpression)

        // SteamID3 form, `[U:1:<accountid>]`. Empirically present in SteamCMD
        // `+info` output (`SteamID: [U:1:1267132100]`).
        output = output.replacingOccurrences(
            of: #"\[U:\d+:\d+\]"#,
            with: "<steamid3>",
            options: .regularExpression
        )

        // IPv4 dotted quad.
        output = output.replacingOccurrences(of: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, with: "<ipv4>", options: .regularExpression)

        // IPv6 (deliberately permissive — anything with 2+ colon-separated
        // hex groups gets scrubbed; false-positive risk is acceptable in a
        // diagnostic payload).
        output = output.replacingOccurrences(
            of: #"\b(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}\b"#,
            with: "<ipv6>",
            options: .regularExpression
        )

        // cellid / serverid query params and key/value pairs. Steam writes
        // the same field in three styles depending on surface:
        //   * Web API query strings: `cellid=2`
        //   * SteamCMD `+info`     : `CellID: 2` / `CellID:2`
        //   * legacy logs          : `cellid: 2`
        // The case-insensitive flag and the `[:= ]+` separator cover all three.
        output = output.replacingOccurrences(
            of: #"(?i)\b(cellid|serverid)[:= ]+\d+\b"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )

        // Email.
        output = output.replacingOccurrences(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, with: "<email>", options: .regularExpression)

        // ssfn* (SteamCMD session token file names).
        output = output.replacingOccurrences(of: #"ssfn[A-Za-z0-9]+"#, with: "<ssfn>", options: .regularExpression)

        // Home directory.
        let home = NSHomeDirectory()
        if !home.isEmpty {
            output = output.replacingOccurrences(of: home, with: "<home>")
        }

        // Short-name account login. `NSUserName()` is the macOS POSIX user
        // login, which Steam logs surface as the workdir owner. Replace
        // word-boundary occurrences so we don't accidentally cut into longer
        // identifiers (e.g. a username appearing inside a URL token).
        let username = NSUserName()
        if !username.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: username)
            output = output.replacingOccurrences(
                of: "\\b\(escaped)\\b",
                with: "<username>",
                options: .regularExpression
            )
        }

        // personaname= query strings.
        output = output.replacingOccurrences(of: #"personaname=[^&\s]+"#, with: "personaname=<redacted>", options: .regularExpression)

        // SteamCMD `+info` emits a free-form `Persona Name: <name>` line.
        // The persona handle is user-chosen and can include spaces, kanji,
        // emoji, etc. The `.+?` plus optional trailing whitespace + EOL
        // matches both "Persona Name: foo" and "Persona Name: foo " (the
        // trailing-space form is what SteamCMD actually emits).
        output = output.replacingOccurrences(
            of: #"(?im)^Persona Name:\s*\S.*?\s*$"#,
            with: "Persona Name: <redacted>",
            options: .regularExpression
        )

        // SteamCMD `+info` also emits `Account: <login_name>` — the Steam
        // login name, distinct from the macOS shell username we already
        // redact above. The line frequently carries trailing whitespace,
        // so `\s*$` (not `$`) is the right anchor.
        output = output.replacingOccurrences(
            of: #"(?im)^Account:\s*\S+\s*$"#,
            with: "Account: <redacted>",
            options: .regularExpression
        )

        // `Logging in user '<name>' [U:1:N] to Steam Public...OK` —
        // explicit login banner. The SteamID3 part is already redacted by
        // the rule above; this one nukes the embedded username so it cannot
        // leak even if it does not appear elsewhere in the document.
        output = output.replacingOccurrences(
            of: #"Logging in user '[^']+'"#,
            with: "Logging in user '<redacted>'",
            options: .regularExpression
        )

        return output
    }
}
#endif
