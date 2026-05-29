#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// The pane's "Installed" tab, backed by the app-managed Wallpaper Engine
/// library (the WPE import history + cache). Everything imported via
/// paste-preview or a SteamCMD download lands here automatically; "Import from
/// folder…" pulls in an existing external Wallpaper Engine library on demand.
/// Rendered headerless — `WorkshopPaneView` owns the chrome.
struct WorkshopInstalledView: View {
    let allowsTargetSelection: Bool

    @Environment(ScreenManager.self) private var screenManager
    @State private var entries: [WPEHistoryEntry] = []
    @State private var selectedTargetScreenID: CGDirectDisplayID?
    @State private var isImportingFromFolder = false
    @State private var isApplying = false
    @State private var errorMessage: String?

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: DesignTokens.Spacing.lg)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(DesignTokens.Colors.pageBackground)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in reload() }
        .sheet(isPresented: $isImportingFromFolder) {
            // Reuse the existing external-folder scanner as the import flow;
            // applying a scanned project records it into the managed library,
            // so it then appears here.
            WorkshopGalleryView(allowsTargetSelection: false)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if allowsTargetSelection, !screenManager.screens.isEmpty {
                Picker("Apply to", selection: Binding(
                    get: { selectedTargetScreenID ?? screenManager.screens.first?.id },
                    set: { selectedTargetScreenID = $0 }
                )) {
                    ForEach(screenManager.screens, id: \.id) { screen in
                        Text(verbatim: screen.name).tag(Optional(screen.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 150)
                .help(Text("Choose which display receives Apply actions"))
                .accessibilityLabel(Text("Apply to display"))
            }

            Spacer(minLength: 0)

            Button {
                isImportingFromFolder = true
            } label: {
                Label("Import from folder…", systemImage: "folder.badge.plus")
            }
            .controlSize(.small)
            .help(Text("Scan an existing Wallpaper Engine library folder and add projects to your library"))
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                LazyVGrid(columns: gridColumns, spacing: DesignTokens.Spacing.lg) {
                    ForEach(entries, id: \.id) { entry in
                        WPEHistoryRow(
                            entry: entry,
                            isActive: isActive(entry),
                            onTap: { Task { await apply(entry) } },
                            onRemove: { remove(entry) }
                        )
                    }
                }
                .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
            }
            .disabled(isApplying)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No wallpapers installed yet.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Download from Browse Online, paste a Workshop URL, or import an existing library folder.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                isImportingFromFolder = true
            } label: {
                Label("Import from folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    // MARK: - Actions

    private var targetScreen: Screen? {
        if let id = selectedTargetScreenID {
            return screenManager.screens.first { $0.id == id }
        }
        return screenManager.screens.first
    }

    private func isActive(_ entry: WPEHistoryEntry) -> Bool {
        guard let screen = targetScreen else { return false }
        return screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID == entry.origin.workshopID
    }

    private func apply(_ entry: WPEHistoryEntry) async {
        guard let screen = targetScreen else {
            errorMessage = String(localized: "Open a display first, then apply a wallpaper.", comment: "Workshop installed apply error: no display.")
            return
        }
        errorMessage = nil
        isApplying = true
        await screenManager.activateWPEHistoryEntry(entry, for: screen)
        isApplying = false
        if screenManager.wpeImportError(for: screen) != nil {
            errorMessage = String(localized: "Couldn't apply \(entry.origin.title).", comment: "Workshop installed apply failure. Placeholder is the wallpaper title.")
        }
        reload()
    }

    private func remove(_ entry: WPEHistoryEntry) {
        screenManager.removeWPEImport(workshopID: entry.id)
        reload()
    }

    private func reload() {
        entries = SettingsManager.shared.loadGlobalSettings().recentWPEImports
    }
}
#endif
