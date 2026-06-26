#if !LITE_BUILD
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
    /// IDs the user must subscribe to in Steam before retrying the import.
    case missingDependency(workshopIDs: [String])
    /// Windows `.dll` plugin under `bin/`. Permanent on macOS — subscribing
    /// more workshop items will not help.
    case requiresWindowsPlugin
    // Precise codes so the user sees "Format 8 (RGBA1010102) not yet
    // supported" instead of a vague "scene unsupported".
    case texContainerUnsupported(magic: String)
    case texUnsupportedFormat(code: Int)
    case texDecodeFailed(detail: String)
}

/// Explanatory card for any WPE workshop import that cannot be promoted to a
/// live wallpaper, with reason-aware copy.
struct WPEFallbackCard: View {
    let origin: WPEOrigin
    let reason: FallbackReason

    init(origin: WPEOrigin, reason: FallbackReason = .unsupportedType) {
        self.origin = origin
        self.reason = reason
    }

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
                Text(verbatim: origin.title)
                    .font(DesignTokens.Typography.pageTitle)
                    .multilineTextAlignment(.center)
                Text("Workshop ID \(origin.workshopID) · \(origin.localizedDisplayTypeName) type", comment: "Wallpaper Engine metadata line. Placeholders are Workshop ID and project type.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(reason.severityTint)
                    Text(verbatim: warningTitle)
                        .font(.headline)
                }

                Text(verbatim: warningBody)
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
            .background(reason.severityTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(origin.title). \(warningTitle). \(warningBody)"))

            primaryAction
        }
        .padding(32)
        .frame(maxWidth: 480)
        .adaptiveGlassSurface(.roundedRectangle(24))
    }

    @ViewBuilder
    private func dependencyList(ids: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: id)
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
                        .help(Text("Open workshop \(id) in browser"))
                        .accessibilityLabel(Text("Open workshop \(id) in browser"))
                        Button {
                            copyToPasteboard(id)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Copy workshop ID to clipboard"))
                        .accessibilityLabel(Text("Copy workshop ID \(id)"))
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
                .adaptiveGlassButton(.regular)
                .controlSize(.regular)
                .accessibilityHint(Text("Copies every missing workshop ID to your clipboard so you can subscribe in Steam"))

                Button {
                    openWorkshop()
                } label: {
                    Label("Open this project", systemImage: "arrow.up.right.square")
                }
                .adaptiveGlassButton(.regular)
                .controlSize(.regular)
            }

        default:
            Button {
                openWorkshop()
            } label: {
                Label("View in Workshop", systemImage: "arrow.up.right.square")
            }
            .adaptiveGlassButton(.regular)
            .controlSize(.regular)
            .accessibilityHint(Text("Opens this wallpaper's Steam Workshop page in your browser"))
        }
    }

    private var warningTitle: String {
        switch reason {
        case .unsupportedType:
            switch origin.originalType {
            case .scene:
                return String(localized: "Scene format coming later", defaultValue: "Scene format coming later", comment: "Wallpaper Engine fallback warning title.")
            case .application:
                return String(localized: "Executable wallpapers can't be imported", defaultValue: "Executable wallpapers can't be imported", comment: "Wallpaper Engine fallback warning title.")
            default:
                return String(localized: "This wallpaper type is not supported", defaultValue: "This wallpaper type is not supported", comment: "Wallpaper Engine fallback warning title.")
            }
        case .sceneParseFailed:
            return String(localized: "Couldn't read scene.json", defaultValue: "Couldn't read scene.json", comment: "Wallpaper Engine fallback warning title.")
        case .sceneShaderUnsupported:
            return String(localized: "Scene uses unsupported shaders", defaultValue: "Scene uses unsupported shaders", comment: "Wallpaper Engine fallback warning title.")
        case .sceneResourceMissing:
            return String(localized: "Some scene assets are missing", defaultValue: "Some scene assets are missing", comment: "Wallpaper Engine fallback warning title.")
        case .missingDependency(let ids):
            if ids.count == 1 {
                return String(localized: "Missing 1 Workshop dependency", defaultValue: "Missing 1 Workshop dependency", comment: "Wallpaper Engine fallback warning title.")
            }
            return String(localized: "Missing \(ids.count) Workshop dependencies", comment: "Wallpaper Engine fallback warning title. The placeholder is the missing dependency count.")
        case .requiresWindowsPlugin:
            return String(localized: "Windows plugin required", defaultValue: "Windows plugin required", comment: "Wallpaper Engine fallback warning title.")
        case .texContainerUnsupported:
            return String(localized: "Texture container not supported yet", defaultValue: "Texture container not supported yet", comment: "Wallpaper Engine fallback warning title.")
        case .texUnsupportedFormat:
            return String(localized: "Image format not supported yet", defaultValue: "Image format not supported yet", comment: "Wallpaper Engine fallback warning title.")
        case .texDecodeFailed:
            return String(localized: "Couldn't read texture file", defaultValue: "Couldn't read texture file", comment: "Wallpaper Engine fallback warning title.")
        }
    }

    private var warningBody: String {
        switch reason {
        case .unsupportedType:
            switch origin.originalType {
            case .scene:
                return String(localized: "This scene needs rendering features that are not supported on Mac yet. We're working on broader Phase 2 support — your other wallpapers continue to play unaffected.", defaultValue: "This scene needs rendering features that are not supported on Mac yet. We're working on broader Phase 2 support — your other wallpapers continue to play unaffected.", comment: "Scene fallback warning body.")
            case .application:
                return String(localized: "For your security, LiveWallpaper does not run executable workshop projects.", defaultValue: "For your security, LiveWallpaper does not run executable workshop projects.", comment: "Wallpaper Engine fallback warning body.")
            default:
                return String(localized: "We couldn't recognize this project type.", defaultValue: "We couldn't recognize this project type.", comment: "Project fallback warning body.")
            }
        case .sceneParseFailed(let detail):
            return String(localized: "The author's scene.json couldn't be parsed: \(detail)", comment: "Wallpaper Engine fallback warning body. The placeholder is parser detail.")
        case .sceneShaderUnsupported:
            return String(localized: "This scene uses a custom shader the renderer couldn't translate to Metal. Try re-downloading the project in Steam.", defaultValue: "This scene uses a custom shader the renderer couldn't translate to Metal. Try re-downloading the project in Steam.", comment: "Wallpaper Engine fallback warning body.")
        case .sceneResourceMissing:
            return String(localized: "Some assets the scene needs aren't where the renderer expected them. The renderer ships built-in equivalents for the most common Wallpaper Engine framework files; if this scene needs something extra, an advanced option in the Workshop Library lets you link a Wallpaper Engine install. Otherwise, re-downloading the project in Steam usually fixes it.", defaultValue: "Some assets the scene needs aren't where the renderer expected them. The renderer ships built-in equivalents for the most common Wallpaper Engine framework files; if this scene needs something extra, an advanced option in the Workshop Library lets you link a Wallpaper Engine install. Otherwise, re-downloading the project in Steam usually fixes it.", comment: "Wallpaper Engine fallback warning body.")
        case .missingDependency:
            return String(localized: "This wallpaper relies on other Workshop projects we don't have on disk yet. Subscribe to them in Steam, then re-import this folder.", defaultValue: "This wallpaper relies on other Workshop projects we don't have on disk yet. Subscribe to them in Steam, then re-import this folder.", comment: "Wallpaper Engine fallback warning body.")
        case .requiresWindowsPlugin:
            return String(localized: "This wallpaper bundles a Windows `.dll` plugin (e.g. an audio visualizer or screensaver runtime). macOS can't load Windows native code, so the project is permanently unsupported here.", defaultValue: "This wallpaper bundles a Windows `.dll` plugin (e.g. an audio visualizer or screensaver runtime). macOS can't load Windows native code, so the project is permanently unsupported here.", comment: "Wallpaper Engine fallback warning body.")
        case .texContainerUnsupported(let magic):
            return String(localized: "This wallpaper uses a `.tex` container we don't decode yet (\(magic)). Phase 2.x will keep widening coverage as new versions appear.", comment: "Wallpaper Engine fallback warning body. The placeholder is a texture container magic value.")
        case .texUnsupportedFormat(let code):
            switch code {
            case 8:
                return String(localized: "Texture format 8 (RGBA1010102) is rare and pending decoder support. Most other layers in this scene should still render.", defaultValue: "Texture format 8 (RGBA1010102) is rare and pending decoder support. Most other layers in this scene should still render.", comment: "Texture fallback warning body.")
            case -1:
                return String(localized: "This format requires Metal-backed GPU decoding that this Mac doesn't support. Try rendering on a newer GPU.", defaultValue: "This format requires Metal-backed GPU decoding that this Mac doesn't support. Try rendering on a newer GPU.", comment: "Wallpaper Engine fallback warning body.")
            default:
                return String(localized: "Texture format \(code) is not in the Phase 2.1 decoder. The renderer skips just this layer; the rest of the scene continues.", comment: "Texture fallback warning body. The placeholder is a texture format code.")
            }
        case .texDecodeFailed(let detail):
            return String(localized: "A texture failed to decode (\(detail)). Re-downloading the wallpaper in Steam usually fixes it.", comment: "Wallpaper Engine fallback warning body. The placeholder is decode detail.")
        }
    }

    private var previewURL: URL? {
        origin.sourcePreviewURL
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

extension FallbackReason {
    /// Two distinct tints so users can skim "subscribe to fix" (recoverable)
    /// vs "macOS can't run this" (permanent block).
    var severityTint: Color {
        switch self {
        case .requiresWindowsPlugin:
            return DesignTokens.Colors.Status.warning
        case .unsupportedType,
             .sceneShaderUnsupported,
             .texContainerUnsupported,
             .texUnsupportedFormat:
            return DesignTokens.Colors.Status.warning
        case .missingDependency,
             .sceneParseFailed,
             .sceneResourceMissing,
             .texDecodeFailed:
            return DesignTokens.Colors.Status.caution
        }
    }

    /// Reason categories where the user can take a concrete action and
    /// retry — drives the inline Retry button on the detail view.
    var isActionable: Bool {
        switch self {
        case .missingDependency,
             .sceneParseFailed,
             .sceneResourceMissing,
             .texDecodeFailed:
            return true
        case .unsupportedType,
             .sceneShaderUnsupported,
             .requiresWindowsPlugin,
             .texContainerUnsupported,
             .texUnsupportedFormat:
            return false
        }
    }
}
#endif
