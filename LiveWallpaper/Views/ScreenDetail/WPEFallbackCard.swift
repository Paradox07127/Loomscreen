import SwiftUI
import AppKit

/// Why a Wallpaper Engine workshop project couldn't be activated. Surfaced
/// to the inspector so the user gets a specific reason instead of a generic
/// "unsupported" message.
enum FallbackReason: Equatable, Sendable {
    case unsupportedType
    case sceneParseFailed(String)
    case sceneShaderUnsupported
    case sceneResourceMissing
}

/// Renders the explanatory card for any WPE workshop import that cannot be
/// promoted to a live wallpaper. Replaces the Phase 1.x `WPEUnsupportedCard`
/// with a reason-aware variant so scene parse failures, missing assets, and
/// genuinely unsupported types each get their own copy.
struct WPEFallbackCard: View {
    let origin: WPEOrigin
    let reason: FallbackReason

    init(origin: WPEOrigin, reason: FallbackReason = .unsupportedType) {
        self.origin = origin
        self.reason = reason
    }

    var body: some View {
        VStack(spacing: 24) {
            WPEPreviewView(
                imageURL: previewURL,
                securityScopedBookmarkData: origin.sourceFolderBookmark
            )
                .frame(width: 280)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 4)

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

                if origin.originalType == .scene && reason == .unsupportedType {
                    Text("Tip: many creators publish a video version of the same wallpaper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(origin.title). \(warningTitle). \(warningBody)")
    }

    private var warningTitle: String {
        switch reason {
        case .unsupportedType:
            switch origin.originalType {
            case .scene:       return "Scene format coming later"
            case .application: return "Executable wallpapers can't be imported"
            default:           return "This wallpaper type is not supported"
            }
        case .sceneParseFailed:
            return "Couldn't read scene.json"
        case .sceneShaderUnsupported:
            return "Scene uses unsupported shaders"
        case .sceneResourceMissing:
            return "Some scene assets are missing"
        }
    }

    private var warningBody: String {
        switch reason {
        case .unsupportedType:
            switch origin.originalType {
            case .scene:
                return "This wallpaper needs Wallpaper Engine's own 3D rendering engine to play. We're working on broader Phase 2 support — your other wallpapers continue to play unaffected."
            case .application:
                return "For your security, LiveWallpaper does not run executable workshop projects."
            default:
                return "We couldn't recognize this Wallpaper Engine project type."
            }
        case .sceneParseFailed(let detail):
            return "Phase 2.0 ships an image-only renderer. The author's scene.json couldn't be parsed: \(detail)"
        case .sceneShaderUnsupported:
            return "This scene relies on custom shaders that the image-only Phase 2.0 renderer can't compile yet."
        case .sceneResourceMissing:
            return "Some image layers couldn't be located inside the cache. The wallpaper may have been published partially or your cache is corrupted."
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

/// Compatibility shim — keeps the old name compiling while Phase 2.x consumers
/// migrate. Defaults the reason to `.unsupportedType` so the historical
/// behaviour (badge for unsupported workshop types) is unchanged.
struct WPEUnsupportedCard: View {
    let origin: WPEOrigin

    var body: some View {
        WPEFallbackCard(origin: origin, reason: .unsupportedType)
    }
}
