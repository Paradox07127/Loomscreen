#if !LITE_BUILD
import SwiftUI
import AppKit

/// Single recent-import card in the Scene tab grid. Adaptive width
/// (160-240pt) × height (240-320pt) per `wpeProjectCardChrome`, glass-effect
/// background, hover lift, context menu for Finder/remove.
struct WPEHistoryRow: View {
    let entry: WPEHistoryEntry
    let isActive: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
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
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .wpeProjectCardChrome(isHovering: isHovering, reduceMotion: reduceMotion)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(
            "Imported project: \(entry.origin.title)",
            comment: "A11y label for an imported project history row card. The placeholder is the project title."
        ))
        .accessibilityHint(isActive
            ? Text("Currently in use. Tap to reactivate.", comment: "A11y hint for a WPE history row that is the active wallpaper.")
            : Text("Tap to apply", comment: "A11y hint for a WPE history row that can be applied."))
        .contextMenu {
            Button("Show in Finder") { showInFinder() }
            Button("Remove", role: .destructive, action: onRemove)
        }
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
