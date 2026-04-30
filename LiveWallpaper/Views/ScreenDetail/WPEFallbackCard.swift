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
    /// Project declares Steam Workshop dependencies we couldn't satisfy
    /// from the local cache. Lists IDs the user must subscribe to in
    /// Steam before retrying the import.
    case missingDependency(workshopIDs: [String])
    /// Project ships a Windows `.dll` plugin under `bin/`. Permanent on
    /// macOS — subscribing more workshop items will not help.
    case requiresWindowsPlugin
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

    /// Picks the card-level reason from a freshly imported origin so callers
    /// don't have to reach into the new `WPEOrigin` flags themselves. Order
    /// matters: plugin > missing-deps > generic unsupported.
    static func reason(for origin: WPEOrigin) -> FallbackReason {
        if origin.requiresWindowsPlugin { return .requiresWindowsPlugin }
        if !origin.missingDependencyIDs.isEmpty {
            return .missingDependency(workshopIDs: origin.missingDependencyIDs)
        }
        return .unsupportedType
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

                if case .missingDependency(let ids) = reason {
                    dependencyList(ids: ids)
                }

                if origin.originalType == .scene && reason == .unsupportedType {
                    Text("Tip: many creators publish a video version of the same wallpaper.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
            // Combine ONLY the warning text into a single VoiceOver element
            // so the title + body announce together, while leaving the
            // dependency list rows and primary buttons individually
            // focusable. Applying `.combine` at the card root would flatten
            // every interactive control into the same element and hide them
            // from assistive tech.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(origin.title). \(warningTitle). \(warningBody)")

            primaryAction
        }
        .padding(32)
        .frame(maxWidth: 480)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    /// Renders one row per missing workshop ID. Wraps the list in a
    /// bounded `ScrollView` so a project that declares 10+ dependencies
    /// (rare but real for composite scenes) does not push the primary
    /// action buttons off-screen.
    @ViewBuilder
    private func dependencyList(ids: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(id)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            openWorkshop(workshopID: id)
                        } label: {
                            Label("Open", systemImage: "arrow.up.right.square")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Open workshop \(id) in browser")
                        .accessibilityLabel("Open workshop \(id) in browser")
                        Button {
                            copyToPasteboard(id)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy workshop ID to clipboard")
                        .accessibilityLabel("Copy workshop ID \(id)")
                    }
                }
            }
        }
        .frame(maxHeight: 160)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch reason {
        case .missingDependency(let ids):
            HStack(spacing: 8) {
                Button {
                    copyToPasteboard(ids.joined(separator: "\n"))
                } label: {
                    Label("Copy all IDs", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .accessibilityHint("Copies every missing workshop ID to your clipboard so you can subscribe in Steam")

                Button {
                    openWorkshop()
                } label: {
                    Label("Open this project", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
            }

        default:
            Button {
                openWorkshop()
            } label: {
                Label("View in Workshop", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .accessibilityHint("Opens this wallpaper's Steam Workshop page in your browser")
        }
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
        case .missingDependency(let ids):
            return "Missing \(ids.count) Workshop \(ids.count == 1 ? "dependency" : "dependencies")"
        case .requiresWindowsPlugin:
            return "Windows plugin required"
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
        case .missingDependency:
            return "This wallpaper relies on other Workshop projects we don't have on disk yet. Subscribe to them in Steam, then re-import this folder."
        case .requiresWindowsPlugin:
            return "This wallpaper bundles a Windows `.dll` plugin (e.g. an audio visualizer or screensaver runtime). macOS can't load Windows native code, so the project is permanently unsupported here."
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
        openWorkshop(workshopID: origin.workshopID)
    }

    private func openWorkshop(workshopID: String) {
        var components = URLComponents(string: "https://steamcommunity.com/sharedfiles/filedetails/")
        components?.queryItems = [URLQueryItem(name: "id", value: workshopID)]
        guard let url = components?.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// Compatibility shim — keeps the old name compiling while Phase 2.x consumers
/// migrate. Defaults the reason to `.unsupportedType` so the historical
/// behaviour (badge for unsupported workshop types) is unchanged.
struct WPEUnsupportedCard: View {
    let origin: WPEOrigin

    var body: some View {
        WPEFallbackCard(origin: origin, reason: WPEFallbackCard.reason(for: origin))
    }
}
