#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Used by Doctor probes and Phase 3 download failures. Offers a redacted
/// command preview plus Copy and Open-Terminal actions; never auto-executes.
struct TerminalCommandPanel: View {
    let command: String
    let redactedPreview: Bool
    let onCopied: () -> Void

    init(command: String, redactedPreview: Bool = false, onCopied: @escaping () -> Void = {}) {
        self.command = command
        self.redactedPreview = redactedPreview
        self.onCopied = onCopied
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(previewCommand)
                    .font(DesignTokens.Typography.codeCaption)
                    .foregroundStyle(.primary)
                    .padding(.vertical, DesignTokens.Spacing.xxs)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button(action: copyToClipboard) {
                    Label("Copy", systemImage: "doc.on.clipboard")
                        .font(DesignTokens.Typography.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(Text("Copy command to clipboard"))

                Button(action: openTerminal) {
                    Label("Terminal", systemImage: "terminal")
                        .font(DesignTokens.Typography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Open Terminal.app"))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var previewCommand: String {
        guard redactedPreview else { return command }
        var parts = command.components(separatedBy: " ")
        if let loginIndex = parts.firstIndex(of: "+login"),
           loginIndex + 1 < parts.count,
           !parts[loginIndex + 1].hasPrefix("+") {
            parts[loginIndex + 1] = "<username>"
        }
        return parts.joined(separator: " ")
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(command, forType: .string)
        onCopied()
    }

    private func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}
#endif
