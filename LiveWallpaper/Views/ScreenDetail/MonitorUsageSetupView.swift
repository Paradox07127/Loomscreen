import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Standalone sheet explaining how to feed Claude Code account rate limits into
/// the Monitor. The app can't install anything (its `~/.claude` grant is
/// read-only), so it shows copy-paste snippets the user runs once in their own
/// terminal. Nothing here executes — every snippet is a string with a Copy button.
///
/// The lead wires a button in `MonitorDetailView` to present this; this file
/// deliberately owns no pipeline state.
struct MonitorUsageSetupView: View {
    /// The user's existing `statusLine.command`, if the caller detected one, so
    /// the generated settings fragment chains through to it.
    var existingStatusLineCommand: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // The install snippet alone is ~40 lines: the content MUST scroll and
        // the Done button MUST live in a fixed footer, or the sheet overflows
        // with no visible way to close it.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    header

                    Text(explanation)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    copyBlock(
                        title: String(
                            localized: "1. Install the capture script",
                            defaultValue: "1. Install the capture script",
                            comment: "Monitor rate-limit setup: step 1 heading."
                        ),
                        caption: String(
                            localized: "Run this once in Terminal. It writes a small script into ~/.claude and never edits your settings.",
                            defaultValue: "Run this once in Terminal. It writes a small script into ~/.claude and never edits your settings.",
                            comment: "Monitor rate-limit setup: step 1 caption."
                        ),
                        snippet: ClaudeStatuslineInstaller.installCommand,
                        snippetMaxHeight: 180
                    )

                    copyBlock(
                        title: String(
                            localized: "2. Enable the statusline",
                            defaultValue: "2. Enable the statusline",
                            comment: "Monitor rate-limit setup: step 2 heading."
                        ),
                        caption: ClaudeStatuslineInstaller.settingsGuidance(existingCommand: existingStatusLineCommand),
                        snippet: ClaudeStatuslineInstaller.settingsFragment(existingCommand: existingStatusLineCommand)
                    )

                    uninstallDisclosure
                }
                .padding(DesignTokens.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .background {
            // Esc closes the sheet even though the footer button is Return.
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .frame(width: 560, height: 640)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Account usage limits")
                .font(DesignTokens.Typography.sectionTitle)
        }
    }

    private var explanation: String {
        String(
            localized: "The Monitor can show how much of your Claude account's 5-hour and weekly limits you've used. Claude Code reports this to its statusline; the two steps below tee that data into a file the app reads. Your own statusline keeps working.",
            defaultValue: "The Monitor can show how much of your Claude account's 5-hour and weekly limits you've used. Claude Code reports this to its statusline; the two steps below tee that data into a file the app reads. Your own statusline keeps working.",
            comment: "Monitor rate-limit setup: 2-3 sentence explanation of what the sheet configures."
        )
    }

    private func copyBlock(title: String, caption: String, snippet: String, snippetMaxHeight: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.Typography.bodyEmphasized)
            Text(caption)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SnippetBox(snippet: snippet, maxHeight: snippetMaxHeight)
        }
    }

    private var uninstallDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Removes the capture script and its data file. If you added the statusLine block to settings.json, restore your previous statusLine afterward.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SnippetBox(snippet: ClaudeStatuslineInstaller.uninstallCommand)
            }
            .padding(.top, DesignTokens.Spacing.xs)
        } label: {
            Text("Uninstall")
                .font(DesignTokens.Typography.caption)
        }
    }
}

/// A selectable monospaced snippet with a Copy button. Kept private to this
/// sheet; the app never runs the contents.
private struct SnippetBox: View {
    let snippet: String
    /// Tall snippets (the install script) scroll inside a bounded well instead
    /// of inflating the sheet.
    var maxHeight: CGFloat?

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Group {
                if let maxHeight {
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        snippetText
                    }
                    .frame(height: maxHeight)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        snippetText
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    .font(DesignTokens.Typography.caption)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(Text("Copy to clipboard"))
            .padding(DesignTokens.Spacing.xs)
        }
        .background(Color(.textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var snippetText: some View {
        Text(snippet)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .padding(DesignTokens.Spacing.sm)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
