import SwiftUI
import AppKit

/// Single recent-import card in the Scene tab grid. 160×240pt,
/// glass-effect background, hover lift, context menu for Finder/remove.
struct WPEHistoryRow: View {
    let entry: WPEHistoryEntry
    let isActive: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Square preview occupies the full card width (140×140) so
                // 1:1 sources render flush. Card height adjusts below to fit.
                WPEPreviewView(
                    imageURL: previewURL,
                    securityScopedBookmarkData: entry.origin.sourceFolderBookmark
                )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 16,
                            style: .continuous
                        )
                    )
                    .overlay(alignment: .topTrailing) {
                        if let badge = compatibilityBadge {
                            Text(badge.label)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badge.tint.opacity(0.85), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(8)
                                .accessibilityLabel(badge.accessibility)
                        }
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.origin.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(typeColor)
                            .frame(width: 6, height: 6)
                        Text(entry.origin.displayTypeName)
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
        .frame(width: 160, height: 240)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .shadow(
            color: Color.black.opacity(isHovering ? 0.18 : 0.06),
            radius: isHovering ? 8 : 4,
            y: isHovering ? 4 : 2
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Wallpaper Engine project: \(entry.origin.title)")
        .accessibilityHint(isActive ? "Currently in use. Tap to reactivate." : "Tap to apply")
        .contextMenu {
            Button("Show in Finder") { showInFinder() }
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    private var previewURL: URL? {
        guard let previewName = entry.origin.previewFileName,
              let folder = resolveFolderURL() else { return nil }
        return folder.appendingPathComponent(previewName)
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
    private var compatibilityBadge: (label: String, tint: Color, accessibility: String)? {
        switch entry.origin.originalType {
        case .video, .web:
            return nil
        case .application:
            return ("Won't run", .orange, "Wallpaper requires a Windows executable; cannot run on macOS")
        case .scene:
            if entry.origin.requiresWindowsPlugin {
                return ("Won't run", .orange, "Wallpaper bundles a Windows DLL plugin; cannot run on macOS")
            }
            if !entry.origin.missingDependencyIDs.isEmpty {
                return ("Needs deps", .yellow, "Wallpaper depends on Workshop projects you haven't subscribed to")
            }
            // Phase 2.1: scenes are renderable when image-only; default
            // tier is best-effort, so we tag them Experimental until the
            // import service can persist a richer capability summary.
            return ("Experimental", .yellow, "Scene wallpapers are rendered with the Phase 2.1 image-only engine")
        case .unknown:
            return ("Untested", .gray, "Wallpaper Engine project type is unknown")
        }
    }
}
