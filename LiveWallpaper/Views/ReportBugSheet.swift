import LiveWallpaperCore
import SwiftUI

/// Modal sheet shown when the user clicks "Report a Bug…".
struct ReportBugSheet: View {
    let report: BugReport
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sanitizedLogURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            diagnosticPreview

            Divider()

            footer
        }
        .padding(20)
        .frame(
            minWidth: 520,
            idealWidth: 560,
            maxWidth: 720,
            minHeight: 460,
            idealHeight: 520,
            maxHeight: 760
        )
        .task(id: report.id) {
            guard let source = report.logFileURL, report.logFileExists else {
                sanitizedLogURL = nil
                return
            }
            sanitizedLogURL = await Self.makeSanitizedLogCopy(from: source)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text("Report a Bug")
                    .font(.title3.weight(.semibold))
            }

            Text("Thanks for helping LiveWallpaper improve. The information below will be pre-filled into a GitHub issue. **Please review it before posting** — once an issue is created, anyone can read it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnosticPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic snapshot")
                .font(.subheadline.weight(.medium))

            ScrollView {
                Text(verbatim: report.diagnosticMarkdown)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .frame(maxHeight: .infinity)

            if let logURL = sanitizedLogURL {
                Label {
                    Text("Detailed log (sanitized): drag it into the GitHub issue after it opens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .help(Text(verbatim: logURL.path))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("Cancel") {
                onDismiss()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if let logURL = sanitizedLogURL {
                Button {
                    BugReporter.revealLogInFinder(logURL)
                } label: {
                    Label("Show Log in Finder", systemImage: "folder")
                }
                .help(Text("Open Finder and highlight the sanitized log file"))
                .accessibilityLabel(Text("Show sanitized log in Finder"))
            }

            Button {
                BugReporter.openIssueInBrowser(report.issueURL)
                onDismiss()
                dismiss()
            } label: {
                Label("Continue in Browser", systemImage: "arrow.up.right.square")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    /// Scrubs the whole runtime log and writes it to a stable caches path the user can drag after the sheet dismisses.
    nonisolated private static func makeSanitizedLogCopy(from source: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = try? String(contentsOf: source, encoding: .utf8) else { return nil }
            let scrubbed = PIISanitizer.scrub(raw)

            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let destination = caches.appendingPathComponent("LiveWallpaper-log-sanitized.txt")
            do {
                try scrubbed.write(to: destination, atomically: true, encoding: .utf8)
                return destination
            } catch {
                return nil
            }
        }.value
    }
}
