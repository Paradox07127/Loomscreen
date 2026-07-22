import AppKit
import Foundation
import LiveWallpaperCore

/// `Identifiable` so SwiftUI's `.sheet(item:)` can present the report; the id changes on every fresh `makeReport(...)` call so re-opening the sheet re-renders even if the diagnostic content happens to be byte-identical.
struct BugReport: Identifiable, Sendable {
    let id = UUID()
    let diagnosticMarkdown: String
    let issueURL: URL
    let logFileURL: URL?
    let logFileExists: Bool
}

enum BugReporter {
    /// Hardcoded rather than read from a build setting because the issue URL
    /// must survive even if `Bundle` lookups fail.
    private static let issueTemplateURL = URL(
        string: "https://github.com/Paradox07127/Loomscreen/issues/new?template=bug_report.yml"
    ) ?? URL(fileURLWithPath: "/")

    /// How many recent warning/error lines we lift from the runtime log into the markdown preview.
    private static let recentLogLineCount = 5
    private static let maxLogLineLength = 500
    /// Hard cap on the markdown body before URL encoding.
    private static let maxBodyLength = 6 * 1024

    @MainActor
    static func makeReport(activeWallpaperKinds: [String]) -> BugReport {
        let snapshot = SystemSnapshot.capture(activeWallpaperKinds: activeWallpaperKinds)
        let recentLog = sanitizedRecentLogLines()
        let markdown = capped(
            formatMarkdown(snapshot: snapshot, recentLogLines: recentLog),
            to: maxBodyLength
        )
        return BugReport(
            diagnosticMarkdown: markdown,
            issueURL: makeIssueURL(prefilledBody: markdown),
            logFileURL: Logger.persistentLogFileURL,
            logFileExists: logFileExists()
        )
    }

    // MARK: - Markdown

    private static func formatMarkdown(snapshot: SystemSnapshot, recentLogLines: [String]) -> String {
        var sections: [String] = []

        sections.append("""
        <details><summary>Diagnostic snapshot — auto-generated, please review before posting</summary>

        - **App**: LiveWallpaper \(snapshot.appVersion) (Build \(snapshot.appBuild)) — \(snapshot.sku.rawValue) SKU
        - **macOS**: \(snapshot.macOSVersion) (\(snapshot.macOSBuild))
        - **Hardware**: \(snapshot.hardwareModel) · \(snapshot.chip) · \(snapshot.physicalMemoryGiB) GB
        - **Displays**: \(formatDisplays(snapshot.displays))
        - **Active wallpapers**: \(snapshot.activeWallpaperKinds.isEmpty ? "(none)" : snapshot.activeWallpaperKinds.joined(separator: ", "))
        - **Locale**: \(snapshot.localeIdentifier)
        - **Bundle**: `\(snapshot.bundleIdentifier)`
        """)

        if recentLogLines.isEmpty {
            sections.append("- **Recent warnings/errors**: (none recorded)")
        } else {
            // Fenced code block: a single ``` boundary is safer than per-line backticks because it survives `` ` `` characters embedded in the log line itself.
            let fence = safeCodeFence(for: recentLogLines)
            let body = recentLogLines.joined(separator: "\n")
            sections.append("""
            - **Recent warnings/errors** (last \(recentLogLines.count)):

            \(fence)
            \(body)
            \(fence)
            """)
        }

        sections.append("</details>")

        sections.append("""

        ### What happened?
        <!-- describe the bug here -->

        ### Steps to reproduce
        1.&nbsp;
        2.&nbsp;
        3.&nbsp;

        ### Expected vs actual
        <!-- what did you expect? what happened instead? -->
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func formatDisplays(_ displays: [SystemSnapshot.DisplayDescriptor]) -> String {
        guard !displays.isEmpty else { return "(none detected)" }
        let parts = displays.map { d in
            "\(d.pixelWidth)×\(d.pixelHeight) @\(d.backingScaleFactor)x"
        }
        return "\(displays.count) connected (\(parts.joined(separator: " · ")))"
    }

    /// Picks the shortest fence (`` ``` ``, `` ```` ``, …) that does not appear inside any of the lines — preventing user content from prematurely closing the code block.
    private static func safeCodeFence(for lines: [String]) -> String {
        var fence = "```"
        while lines.contains(where: { $0.contains(fence) }) {
            fence += "`"
        }
        return fence
    }

    private static func capped(_ text: String, to maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let limit = maxBytes - 32
        var index = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        while index > text.startIndex && text[..<index].utf8.count > limit {
            index = text.index(before: index)
        }
        return String(text[..<index]) + "\n\n…(diagnostic truncated)"
    }

    // MARK: - GitHub URL

    private static func makeIssueURL(prefilledBody: String) -> URL {
        var components = URLComponents(url: issueTemplateURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "body", value: prefilledBody))
        components.queryItems = items
        return components.url ?? issueTemplateURL
    }

    // MARK: - Runtime log scan

    private static func logFileExists() -> Bool {
        guard let url = Logger.persistentLogFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Pulls the most recent WARNING/ERROR/FAULT lines from `LogFileSink` (which holds the lock so we never observe a torn write or stale rotation).
    private static func sanitizedRecentLogLines() -> [String] {
        LogFileSink.shared
            .recentDiagnosticLines(maxLines: recentLogLineCount, maxLineLength: maxLogLineLength)
    }

    // MARK: - Side-effecting helpers (called from the sheet's button actions)

    @MainActor
    static func revealLogInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    static func openIssueInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
