#if !LITE_BUILD
import SwiftUI
import AppKit

/// Single recent-import card in the managed library grid. Adaptive width
/// (160-240pt) × height (240-320pt) per `wpeProjectCardChrome`, glass-effect
/// background, hover lift, context menu for Finder/remove.
///
/// Two interaction modes:
/// - **Scene tab** (per-screen): whole card is a tap target that applies to the
///   surrounding screen — pass `onTap`, leave `allowsInlineApply` off.
/// - **Installed library** (multi-screen): an explicit per-card Apply control
///   targets the open displays — pass `allowsInlineApply: true` + `screens`.
struct WPEHistoryRow: View {
    let entry: WPEHistoryEntry
    let isActive: Bool
    var allowsInlineApply: Bool = false
    /// Browse-consistent gallery presentation — square tile, controlBackground +
    /// `galleryTileChrome`, uppercase type pill — so the Installed library matches
    /// the redesigned online Browse cards. Default keeps the Scene-tab glass card.
    var galleryStyle: Bool = false
    /// True when this row's detail inspector is open (gallery style only) —
    /// draws the accent selection ring via `galleryTileChrome`.
    var isSelected: Bool = false
    var screens: [Screen] = []
    var onApply: (Screen) -> Void = { _ in }
    var onApplyToAll: () -> Void = {}
    var onTap: () -> Void = {}
    let onRemove: () -> Void
    /// Installed-library bookmark toggle. When `onBookmark` is non-nil a
    /// context-menu item + indicator appear; the Scene-tab call site leaves it
    /// nil so its appearance/behavior is unchanged.
    var isBookmarked: Bool = false
    var onBookmark: (() -> Void)? = nil
    /// "Update available" badge — set when the installed item's Workshop
    /// `timeUpdated` is newer than its import (Installed library only).
    var hasUpdate: Bool = false
    /// Re-download the newer Workshop version. Non-nil only in the Installed
    /// library when an update is available and SteamCMD is ready; adds a
    /// context-menu item. The Scene tab leaves it nil.
    var onUpdate: (() -> Void)? = nil

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        chromedCard
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

    /// The whole card is a tap target that applies the wallpaper — in the
    /// Installed library (`allowsInlineApply`) this replaces the separate Apply
    /// button, so a click (or a drag) sets the wallpaper. The bookmark toggle in
    /// the footer is a nested button and keeps working on its own hit area.
    private var cardContainer: some View {
        Button(action: onTap) { card }
            .buttonStyle(.plain)
    }

    /// Browse-style gallery chrome (solid control surface + `galleryTileChrome`)
    /// vs the legacy Scene-tab glass card. ScreenDetail leaves `galleryStyle`
    /// off, so its rendering is unchanged.
    @ViewBuilder
    private var chromedCard: some View {
        if galleryStyle {
            cardContainer
                .background(Color(nsColor: .controlBackgroundColor))
                .galleryTileChrome(isHovering: isHovering, isSelected: isSelected, reduceMotion: reduceMotion)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            cardContainer
                .wpeProjectCardChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        }
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
                            .background(badge.tint.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(DesignTokens.Spacing.sm)
                            .accessibilityLabel(badge.accessibility)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hasUpdate {
                        updateBadge
                    }
                }

            // Gallery style keeps the thumbnail flush (like the Browse card);
            // the legacy card separates it from the footer with a divider.
            if !galleryStyle {
                Divider()
            }

            VStack(alignment: .leading, spacing: galleryStyle ? DesignTokens.Spacing.xs : DesignTokens.Spacing.sm) {
                Text(verbatim: entry.origin.title)
                    .font(.system(size: 13, weight: .semibold))
                    // Gallery (Installed) reserves two lines so cards are equal
                    // height; the Scene tab keeps its original single-/two-line
                    // sizing (reservesSpace off) so its layout is unchanged.
                    .lineLimit(2, reservesSpace: galleryStyle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    typeIndicator

                    Spacer(minLength: 4)

                    // Visible, state-showing toggle (matches WorkshopGalleryView's
                    // yellow bookmark idiom) — far more discoverable than a
                    // context-menu-only action. Shown only when bookmarking is
                    // wired (Installed library); the Scene tab passes no onBookmark.
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

                    if isActive {
                        HStack(spacing: 3) {
                            Circle().fill(Color.green).frame(width: 4, height: 4)
                            Text("In use")
                        }
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)
            .frame(
                maxWidth: galleryStyle ? .infinity : nil,
                maxHeight: galleryStyle ? nil : .infinity,
                alignment: .top
            )
        }
    }

    /// Type as an uppercase pill (Browse idiom) in gallery style, or the legacy
    /// colored dot + name otherwise.
    @ViewBuilder
    private var typeIndicator: some View {
        if galleryStyle {
            Text(verbatim: entry.origin.localizedDisplayTypeName.uppercased(with: .current))
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
        } else {
            Circle()
                .fill(typeColor)
                .frame(width: 6, height: 6)
            Text(verbatim: entry.origin.localizedDisplayTypeName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
        .background(Color.orange.opacity(0.9), in: Capsule())
        .padding(DesignTokens.Spacing.sm)
        .accessibilityLabel(Text("Update available"))
    }

    /// In the inline-apply (Installed) layout the badge is a separately focusable
    /// child, so the card label stays just the title. In the tap-to-apply (Scene
    /// tab) layout children are `.ignore`d, so the compatibility badge ("Won't
    /// run" / "Needs deps") would be silent to VoiceOver — fold it into the label.
    private var accessibilityCardLabel: Text {
        var label = Text(
            "Imported project: \(entry.origin.title)",
            comment: "A11y label for an imported project history row card. The placeholder is the project title."
        )
        if hasUpdate {
            label = label + Text(verbatim: " — ") + Text("Update available", comment: "A11y: the installed item has a newer version on Steam.")
        }
        if !allowsInlineApply, let badge = compatibilityBadge {
            label = label + Text(verbatim: " — ") + badge.accessibility
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

    private var typeColor: Color {
        switch entry.origin.originalType {
        case .video: return .blue
        case .web: return .green
        case .scene: return .orange
        case .application: return .red
        case .unknown: return .gray
        }
    }

    /// Phase 2.1 thumbnail badge for honest expectation-setting BEFORE the
    /// user taps Apply. Three tiers — clean (no badge), Experimental
    /// (likely degraded), and Won't Run (Windows plugin / unknown).
    /// We deliberately keep this conservative: PNG/JPG video and web
    /// imports get no badge; scene + application + unknown carry one.
    private var compatibilityBadge: (titleKey: LocalizedStringKey, tint: Color, accessibility: Text)? {
        switch entry.origin.originalType {
        case .video, .web:
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
            return ("Experimental", .yellow, Text("Scene wallpapers are rendered with the Phase 2.1 image-only engine"))
        case .unknown:
            return ("Untested", .gray, Text("Project type is unknown"))
        }
    }
}
#endif
