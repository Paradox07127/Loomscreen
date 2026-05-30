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

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if allowsInlineApply {
                card
            } else {
                Button(action: onTap) { card }
                    .buttonStyle(.plain)
            }
        }
        .wpeProjectCardChrome(isHovering: isHovering, reduceMotion: reduceMotion)
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
            if let onBookmark {
                Button(isBookmarked ? "Remove Bookmark" : "Add Bookmark", action: onBookmark)
                Divider()
            }
            Button("Show in Finder") { showInFinder() }
            Button("Remove", role: .destructive, action: onRemove)
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
                            .padding(8)
                            .accessibilityLabel(badge.accessibility)
                    }
                }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: entry.origin.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Circle()
                        .fill(typeColor)
                        .frame(width: 6, height: 6)
                    Text(verbatim: entry.origin.localizedDisplayTypeName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

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

                if allowsInlineApply {
                    applyControl
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Inline apply control (Installed library)

    @ViewBuilder
    private var applyControl: some View {
        if screens.count > 1 {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: {
                applyLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(Text("Apply"))
        } else if let only = screens.first {
            Button { onApply(only) } label: { applyLabel }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 9, verticalPadding: 5))
                .help(Text("Apply"))
        } else {
            Button {} label: { applyLabel }
                .buttonStyle(GlassCapsuleButtonStyle(tint: .secondary, fontSize: 11, horizontalPadding: 9, verticalPadding: 5))
                .disabled(true)
                .help(Text("Open a display first, then apply"))
        }
    }

    private var applyLabel: some View {
        Label(isActive ? "Reapply" : "Apply", systemImage: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    /// In the inline-apply (Installed) layout the badge is a separately focusable
    /// child, so the card label stays just the title. In the tap-to-apply (Scene
    /// tab) layout children are `.ignore`d, so the compatibility badge ("Won't
    /// run" / "Needs deps") would be silent to VoiceOver — fold it into the label.
    private var accessibilityCardLabel: Text {
        let base = Text(
            "Imported project: \(entry.origin.title)",
            comment: "A11y label for an imported project history row card. The placeholder is the project title."
        )
        if !allowsInlineApply, let badge = compatibilityBadge {
            return base + Text(verbatim: " — ") + badge.accessibility
        }
        return base
    }

    private var applyAccessibilityHint: Text {
        if allowsInlineApply {
            return Text("Use the Apply control to set this wallpaper on a display.", comment: "A11y hint for an Installed-library history card with an inline apply control.")
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
