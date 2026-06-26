import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Modal sheet shown when the user clicks "Report a Bug…".
///
/// The sheet never sends anything on its own — the user must click "Continue
/// in Browser" to submit, and the log file stays local until they manually
/// attach it. Matches the privacy posture of indie macOS apps (Ice / Rectangle
/// / Stats).
struct ReportBugSheet: View {
    let report: BugReport
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

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

            if let logURL = report.logFileURL, report.logFileExists {
                Label {
                    Text("Detailed log: drag the runtime log into the GitHub issue after it opens.")
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

            if let logURL = report.logFileURL, report.logFileExists {
                Button {
                    BugReporter.revealLogInFinder(logURL)
                } label: {
                    Label("Show Log in Finder", systemImage: "folder")
                }
                .help(Text("Open Finder and highlight the runtime log file"))
                .accessibilityLabel(Text("Show runtime log in Finder"))
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
}
