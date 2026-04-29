import SwiftUI
import AppKit

/// Centered placeholder shown when the user picks a scene-type or
/// application-type history entry — non-destructive (no wallpaper change).
struct WPEUnsupportedCard: View {
    let origin: WPEOrigin

    var body: some View {
        VStack(spacing: 24) {
            WPEPreviewView(
                imageURL: previewURL,
                securityScopedBookmarkData: origin.sourceFolderBookmark
            )
                .frame(width: 320)

            VStack(spacing: 8) {
                Text(origin.title)
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Workshop ID \(origin.workshopID) · \(origin.displayTypeName) type")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(warningTitle)
                        .font(.headline)
                }

                Text(warningBody)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if origin.originalType == .scene {
                    Text("Tip: many creators publish a video version of the same wallpaper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            Button {
                openWorkshop()
            } label: {
                Label("View in Workshop", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .accessibilityHint("Opens this wallpaper's Steam Workshop page in your browser")
        }
        .padding(32)
        .frame(maxWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var warningTitle: String {
        switch origin.originalType {
        case .scene:       return "Scene format coming later"
        case .application: return "Executable wallpapers can't be imported"
        default:           return "This wallpaper type is not supported"
        }
    }

    private var warningBody: String {
        switch origin.originalType {
        case .scene:
            return "This wallpaper needs Wallpaper Engine's own 3D rendering engine to play. We're working on Phase 2 support — your other wallpapers continue to play unaffected."
        case .application:
            return "For your security, LiveWallpaper does not run executable workshop projects."
        default:
            return "We couldn't recognize this Wallpaper Engine project type."
        }
    }

    private var previewURL: URL? {
        guard let previewName = origin.previewFileName else { return nil }
        var isStale = false
        guard let folder = try? URL(
            resolvingBookmarkData: origin.sourceFolderBookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return folder.appendingPathComponent(previewName)
    }

    private func openWorkshop() {
        var components = URLComponents(string: "https://steamcommunity.com/sharedfiles/filedetails/")
        components?.queryItems = [URLQueryItem(name: "id", value: origin.workshopID)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }
}
