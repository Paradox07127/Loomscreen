#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

struct WorkshopPasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = WorkshopPasteQueueModel()
    @State private var toastVisible = false
    @FocusState private var textFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pasteArea
            Divider()
            queueArea
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 340, idealHeight: 420)
        .background(DesignTokens.Colors.pageBackground)
        .overlay(alignment: .bottom) {
            DiagnosticExportToast(isPresented: $toastVisible)
                .padding(.bottom, 22)
                .allowsHitTesting(false)
        }
        .onAppear { textFieldIsFocused = true }
        .onDisappear { model.removeAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Add from Steam Workshop")
                    .font(DesignTokens.Typography.sectionTitle)
                Text("Paste Workshop URLs or item IDs — newline, comma, or space-separated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)

            Button {
                model.openAllInSteam()
            } label: {
                Image(systemName: "arrow.up.forward.app.fill")
            }
            .controlSize(.small)
            .disabled(model.rows.isEmpty)
            .help(Text("Open all in Steam"))
            .accessibilityLabel(Text("Open all in Steam"))

            Button(role: .destructive) {
                model.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(model.rows.isEmpty)
            .help(Text("Clear queue"))
            .accessibilityLabel(Text("Clear queue"))

            Button("Done") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
    }

    // MARK: - Paste area

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                TextEditor(text: Binding(
                    get: { model.rawInput },
                    set: { model.updateRawInput($0) }
                ))
                .focused($textFieldIsFocused)
                .font(DesignTokens.Typography.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .scrollContentBackground(.hidden)

                if model.rawInput.isEmpty {
                    Text("https://steamcommunity.com/sharedfiles/filedetails/?id=…\n3725117707\nsteam://url/CommunityFilePage/…")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 66, maxHeight: 96)

            HStack(spacing: 8) {
                if let summary = model.lastIngestionSummary, summary != .init(added: 0, duplicates: 0, invalid: 0) {
                    Text(summaryString(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(summaryString(summary)))
                }
                Spacer()
                Button {
                    model.ingestFromRawInput()
                } label: {
                    Label("Add to queue", systemImage: "plus.circle.fill")
                        .font(DesignTokens.Typography.bodyEmphasized)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
    }

    // MARK: - Queue area

    @ViewBuilder
    private var queueArea: some View {
        if model.rows.isEmpty {
            emptyState
        } else {
            queueList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Paste a Workshop URL to get started.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
            Text("Loomscreen reads only the public metadata for each item. Your Steam credentials never enter LiveWallpaper.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.md) {
                ForEach(model.rows) { row in
                    WorkshopPasteRowCard(
                        row: row,
                        onRetry: { model.retry(rowID: row.id) },
                        onRemove: { model.remove(rowID: row.id) },
                        onOpenInSteam: { openInSteam(row) },
                        onCopyDiagnostic: { copyDiagnostic(for: row.id) }
                    )
                }
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        }
    }

    // MARK: - Helpers

    private func openInSteam(_ row: WorkshopPasteQueueModel.Row) {
        guard let url = row.steamURL else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func copyDiagnostic(for rowID: UUID) {
        guard let payload = model.diagnosticPayload(for: rowID) else { return }
        if payload.copyToPasteboard() {
            withAnimation(.easeOut(duration: 0.18)) { toastVisible = true }
        }
    }

    private func summaryString(_ summary: WorkshopPasteQueueModel.IngestionSummary) -> String {
        var fragments: [String] = []
        if summary.added > 0 { fragments.append("\(summary.added) added") }
        if summary.duplicates > 0 { fragments.append("\(summary.duplicates) duplicate") }
        if summary.invalid > 0 { fragments.append("\(summary.invalid) invalid") }
        return fragments.joined(separator: " · ")
    }
}
#endif
