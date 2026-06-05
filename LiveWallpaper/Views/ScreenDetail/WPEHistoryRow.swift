#if !LITE_BUILD
import SwiftUI
import AppKit

/// Shared Wallpaper Engine gallery card used by both the Scene tab and the
/// Installed library grid.
struct WPEHistoryRow: View {
    let entry: WPEHistoryEntry
    let isActive: Bool
    var allowsInlineApply: Bool = false
    var isSelected: Bool = false
    var screens: [Screen] = []
    var onApply: (Screen) -> Void = { _ in }
    var onApplyToAll: () -> Void = {}
    var onTap: () -> Void = {}
    let onRemove: () -> Void
    var isBookmarked: Bool = false
    var onBookmark: (() -> Void)? = nil
    var hasUpdate: Bool = false
    var onUpdate: (() -> Void)? = nil

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        cardContainer
            .galleryTileChrome(
                isHovering: isHovering,
                isSelected: isSelected,
                reduceMotion: reduceMotion,
                useGlass: true
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovering = $0 }
            .accessibilityElement(children: allowsInlineApply ? .contain : .ignore)
            .accessibilityLabel(accessibilityCardLabel)
            .accessibilityHint(applyAccessibilityHint)
            .contextMenu {
                if allowsInlineApply {
                    ForEach(screens, id: \.id) { screen in
                        Button("Apply to \(screen.name)") { onApply(screen) }
                    }
                    if screens.count > 1 {
                        Button("Apply to All Displays", action: onApplyToAll)
                    }
                    if !screens.isEmpty { Divider() }
                }
                if hasUpdate, let onUpdate {
                    Button(action: onUpdate) {
                        Label("Update from Steam", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Divider()
                }
                if let onBookmark {
                    Button(isBookmarked ? "Remove Bookmark" : "Add Bookmark", action: onBookmark)
                    Divider()
                }
                Button("Show in Finder") { showInFinder() }
                Button("Remove", role: .destructive, action: onRemove)
            }
    }

    private var cardContainer: some View {
        Button(action: onTap) { card }
            .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(spacing: 0) {
            WPEPreviewView(
                imageURL: previewURL,
                securityScopedBookmarkData: entry.origin.sourceFolderBookmark,
                playbackMode: .hoverToPlay
            )
            .overlay(alignment: .topTrailing) {
                if let badge = compatibilityBadge {
                    Text(badge.titleKey)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .thumbnailBadgeGlass(tint: badge.tint, opacity: 0.85)
                        .padding(DesignTokens.Spacing.sm)
                        .accessibilityLabel(badge.accessibility)
                }
            }
            .overlay(alignment: .topLeading) {
                if hasUpdate { updateBadge }
            }
            .overlay(alignment: .bottomTrailing) {
                if isActive { activeBadge }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(verbatim: entry.origin.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    TypeBadge(entry.origin.localizedDisplayTypeName)

                    Spacer(minLength: 4)

                    if let onBookmark {
                        Button(action: onBookmark) {
                            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 11))
                                .foregroundStyle(isBookmarked ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isBookmarked ? Text("Remove Bookmark") : Text("Add Bookmark"))
                        .accessibilityLabel(Text(isBookmarked ? "Remove Bookmark" : "Add Bookmark"))
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var updateBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .bold))
            Text("Update")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass(tint: .orange, opacity: 0.9)
        .padding(DesignTokens.Spacing.sm)
        .accessibilityHidden(true)
    }

    private var activeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("In use")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass(tint: Color(red: 0.08, green: 0.35, blue: 0.15), opacity: 0.85)
        .padding(DesignTokens.Spacing.sm)
        .accessibilityHidden(true)
    }

    private var accessibilityCardLabel: Text {
        var label = Text(
            "Imported project: \(entry.origin.title)",
            comment: "A11y label for an imported project history row card. The placeholder is the project title."
        )
        if isActive {
            label = label + Text(verbatim: " — ") + Text("Currently in use", comment: "A11y: this wallpaper is the active one.")
        }
        if hasUpdate {
            label = label + Text(verbatim: " — ") + Text("Update available", comment: "A11y: the installed item has a newer version on Steam.")
        }
        if !allowsInlineApply {
            label = label + Text(verbatim: " — ") + Text(verbatim: entry.origin.localizedDisplayTypeName)
            if let badge = compatibilityBadge {
                label = label + Text(verbatim: " — ") + badge.accessibility
            }
        }
        return label
    }

    private var applyAccessibilityHint: Text {
        if allowsInlineApply {
            return Text("Tap to apply to all displays, or drag onto a display.", comment: "A11y hint for an Installed-library card: the whole card applies the wallpaper.")
        }
        return isActive
            ? Text("Currently in use. Tap to reactivate.", comment: "A11y hint for a WPE history row that is the active wallpaper.")
            : Text("Tap to apply", comment: "A11y hint for a WPE history row that can be applied.")
    }

    private var previewURL: URL? {
        entry.origin.sourcePreviewURL
    }

    private func resolveFolderURL() -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: entry.origin.sourceFolderBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func showInFinder() {
        guard let folder = resolveFolderURL() else { return }
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Actionable pre-apply compatibility badge. Plain scenes carry none — only
    /// hard blockers ("Won't run") and missing dependencies ("Needs deps").
    private var compatibilityBadge: (titleKey: LocalizedStringKey, tint: Color, accessibility: Text)? {
        switch entry.origin.originalType {
        case .video, .web, .unknown:
            return nil
        case .application:
            return ("Won't run", .orange, Text("Wallpaper requires a Windows executable; cannot run on macOS"))
        case .scene:
            if entry.origin.requiresWindowsPlugin {
                return ("Won't run", .orange, Text("Wallpaper bundles a Windows DLL plugin; cannot run on macOS"))
            }
            if !entry.origin.missingDependencyIDs.isEmpty {
                return ("Needs deps", .yellow, Text("Wallpaper depends on Workshop projects you haven't subscribed to"))
            }
            return nil
        }
    }
}
#endif
