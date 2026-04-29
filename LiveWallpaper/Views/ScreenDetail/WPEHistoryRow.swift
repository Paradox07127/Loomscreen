import SwiftUI
import AppKit

/// Single recent-import card in the Scene tab grid. 140×180pt,
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
                WPEPreviewView(
                    imageURL: previewURL,
                    securityScopedBookmarkData: entry.origin.sourceFolderBookmark
                )
                    .frame(height: 80)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 14,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 14,
                            style: .continuous
                        )
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.origin.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
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
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 140, height: 180)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .shadow(
            color: Color.black.opacity(isHovering ? 0.15 : 0.05),
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
}
