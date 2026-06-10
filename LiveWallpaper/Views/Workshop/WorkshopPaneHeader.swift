#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// The shared Workshop pane header — brand mark on the leading edge, the
/// contextual actions trailing — extracted so each tab can host it *inside*
/// its `ResizableInspectorSplit` main column. Placing it there (rather than as
/// a full-width bar above the split) lets the trailing detail panel run
/// full-height alongside the header, matching the screen-detail inspector.
///
/// The Installed / Workshop switcher and the detail-panel toggle do NOT live
/// here: both sit in the window toolbar (`.principal` / `.primaryAction`),
/// mirroring the screen detail's type picker + inspector toggle, so they stay
/// put while this header compresses with the panel.
struct WorkshopPaneHeader: View {
    let selectedTab: WorkshopPaneTab
    let installedCount: Int
    let isImporting: Bool
    let onImport: () -> Void
    let onPaste: () -> Void

    @Environment(WorkshopServices.self) private var services

    var body: some View {
        HStack(spacing: DesignTokens.DetailHeader.contentSpacing) {
            brandMark
                .frame(maxWidth: .infinity, alignment: .leading)

            headerActions
        }
        .padding(.horizontal, DesignTokens.DetailHeader.horizontalPadding)
        .padding(.vertical, DesignTokens.DetailHeader.verticalPadding)
    }

    // Bold title + statistics subtext, matching the Bookmarks / Aerials hero
    // (`DetailHeaderBar`): icon disc, primary semibold title, caption stat line.
    private var brandMark: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(
                        width: DesignTokens.DetailHeader.iconSize,
                        height: DesignTokens.DetailHeader.iconSize
                    )
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: DesignTokens.DetailHeader.iconSymbolSize))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignTokens.DetailHeader.textSpacing) {
                Text("Steam Workshop")
                    .font(.system(size: DesignTokens.DetailHeader.titleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                headerStatView
            }
        }
    }

    /// Hero subtitle. On Workshop it prefixes the request count with the API-key
    /// status seal (the ribbon no longer carries a key chip), so key health and
    /// today's honest request count read in one place.
    private var headerStatView: some View {
        HStack(spacing: 4) {
            if selectedTab == .browseOnline, services.hasWebAPIKey {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.Colors.Status.active)
                    .accessibilityHidden(true)
            }
            Text(verbatim: headerStat)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(selectedTab == .browseOnline && services.hasWebAPIKey
            ? Text("Steam doesn't expose remaining quota; this counts only the requests this Mac has issued today.")
            : Text(""))
    }

    /// Context-aware statistics subtext: library size on Installed, key status +
    /// today's honest request count on Workshop.
    private var headerStat: String {
        switch selectedTab {
        case .installed:
            return String(localized: "\(installedCount) installed", comment: "Workshop header stat: number of installed wallpapers.")
        case .browseOnline:
            if !services.hasWebAPIKey {
                return String(localized: "API key required", comment: "Workshop header stat when no Steam Web API key is set.")
            }
            return String(localized: "\(WorkshopRequestCounter.countForToday()) API requests today", comment: "Workshop header stat: Steam Web API requests issued today.")
        }
    }

    private var headerActions: some View {
        AdaptiveGlassContainer(spacing: 8) {
            HStack(spacing: 8) {
                if selectedTab == .installed {
                    Button {
                        onImport()
                    } label: {
                        if isImporting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "folder.badge.plus")
                        }
                    }
                    .adaptiveGlassButton(.regular)
                    .controlSize(.regular)
                    .disabled(isImporting)
                    .help(Text("Import Wallpaper Engine projects from a folder"))
                    .accessibilityLabel(Text("Import from folder"))
                }

                Button {
                    onPaste()
                } label: {
                    Image(systemName: "plus")
                }
                .adaptiveGlassButton(.regular)
                .controlSize(.regular)
                .help(Text("Add a Steam Workshop item by URL or ID"))
                .accessibilityLabel(Text("Add from Workshop URL or ID"))
            }
        }
    }
}
#endif
