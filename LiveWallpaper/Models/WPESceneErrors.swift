import Foundation

/// Failure modes from `WPESceneDocumentParser` while turning raw `scene.json`
/// bytes into a `WPESceneDocument`. Surfaced through `LocalizedError` so the
/// import service can reuse the same UI alert pipeline as the rest of WPE.
enum WPESceneDocumentError: Error, LocalizedError, Equatable, Sendable {
    case invalidUTF8
    case rootNotObject
    case missingCamera
    case missingGeneral
    case malformedField(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return String(
                localized: "error.scene.document.invalid_utf8",
                defaultValue: "scene.json is not valid UTF-8.",
                comment: "Error shown when a Wallpaper Engine scene.json file is not valid UTF-8."
            )
        case .rootNotObject:
            return String(
                localized: "error.scene.document.root_not_object",
                defaultValue: "scene.json must be a JSON object at the root.",
                comment: "Error shown when a Wallpaper Engine scene.json root value is not an object."
            )
        case .missingCamera:
            return String(
                localized: "error.scene.document.missing_camera",
                defaultValue: "scene.json is missing the required camera block.",
                comment: "Error shown when a Wallpaper Engine scene.json file has no camera block."
            )
        case .missingGeneral:
            return String(
                localized: "error.scene.document.missing_general",
                defaultValue: "scene.json is missing the required general block.",
                comment: "Error shown when a Wallpaper Engine scene.json file has no general block."
            )
        case .malformedField(let field):
            return String(
                localized: "error.scene.document.malformed_field",
                defaultValue: "scene.json field \(field) is malformed.",
                comment: "Error shown when a Wallpaper Engine scene.json field is malformed."
            )
        }
    }
}

/// Failure modes that surface from the scene runtime when a parsed scene
/// cannot be staged. These are observed by the UI state machine and mapped
/// to `FallbackReason` so the user gets a specific message rather than a
/// generic "scene failed to load".
enum SceneRenderingError: Error, LocalizedError, Equatable, Sendable {
    case cacheRootMissing
    case parseFailed(String)
    /// Every layer hit a resource-level failure (decode / missing / unsupported
    /// format / etc.). The associated diagnostic carries the *first* such
    /// failure we encountered so the UI can surface a precise reason instead
    /// of a generic "no renderable objects" message.
    case resourceFailed(SceneLoadDiagnostic)

    var errorDescription: String? {
        switch self {
        case .cacheRootMissing:
            return String(
                localized: "error.scene.rendering.cache_root_missing",
                defaultValue: "Scene cache directory is missing.",
                comment: "Error shown when the extracted scene cache directory cannot be found."
            )
        case .parseFailed(let detail):
            return String(
                localized: "error.scene.rendering.parse_failed",
                defaultValue: "Failed to parse scene.json: \(detail)",
                comment: "Error shown when a Wallpaper Engine scene.json file cannot be parsed."
            )
        case .resourceFailed(let diagnostic):
            return diagnostic.errorDescription
        }
    }
}

/// Per-layer failure recorded by `WPEMetalSceneRenderer.load()`. Used to
/// (a) decide whether the scene mounts in degraded mode (≥1 layer renders)
/// or fails outright, and (b) surface a concrete reason in the developer
/// diagnostic panel and the fallback card.
enum SceneLoadDiagnostic: Equatable, Sendable {
    case texture(layer: String, error: WPETexDecodeError)
    case legacyUnsupportedTexture(layer: String)
    case fileMissing(layer: String, path: String)
    case crossPackageReference(layer: String, path: String)
    /// scene.json points at a `.json` model/material descriptor we
    /// can't follow to a real texture. Used for both built-in WPE util
    /// layers (`models/util/*.json`) and malformed material chains.
    case materialUnresolved(layer: String, reason: String)
    case other(layer: String, message: String)

    var layerName: String {
        switch self {
        case .texture(let layer, _),
             .legacyUnsupportedTexture(let layer),
             .fileMissing(let layer, _),
             .crossPackageReference(let layer, _),
             .materialUnresolved(let layer, _),
             .other(let layer, _):
            return layer
        }
    }

    /// User-facing copy. Phase 2B Task 6 rewrote these strings per the
    /// UX & Frontend Spec in `2026-05-05-wpe-phase2b-scene-runtime-hardening.md`
    /// — the messages name the failing layer in plain language and avoid
    /// engineering jargon ("texture", "shader") that confused users in the
    /// detail view's diagnostic card.
    var errorDescription: String {
        switch self {
        case .texture(let layer, _):
            return String(
                localized: "error.scene.load_diagnostic.texture",
                defaultValue: "The image for '\(layer)' couldn't be loaded.",
                comment: "Diagnostic shown when a scene image layer texture cannot be loaded."
            )
        case .legacyUnsupportedTexture(let layer):
            return String(
                localized: "error.scene.load_diagnostic.legacy_unsupported_texture",
                defaultValue: "The image format used by '\(layer)' is no longer supported.",
                comment: "Diagnostic shown when a scene image layer uses a legacy unsupported texture format."
            )
        case .fileMissing(let layer, _):
            return String(
                localized: "error.scene.load_diagnostic.file_missing",
                defaultValue: "A file required by the '\(layer)' layer is missing.",
                comment: "Diagnostic shown when a scene layer references a missing file."
            )
        case .crossPackageReference(let layer, _):
            return String(
                localized: "error.scene.load_diagnostic.cross_package_reference",
                defaultValue: "The layer '\(layer)' requires files from an external package, which is not supported.",
                comment: "Diagnostic shown when a scene layer references files from another Wallpaper Engine package."
            )
        case .materialUnresolved(let layer, _):
            return String(
                localized: "error.scene.load_diagnostic.material_unresolved",
                defaultValue: "A rendering feature needed by '\(layer)' is not supported yet.",
                comment: "Diagnostic shown when a scene layer uses an unresolved material or rendering feature."
            )
        case .other(let layer, let message):
            return String(
                localized: "error.scene.load_diagnostic.other",
                defaultValue: "The layer '\(layer)' encountered an issue: \(message).",
                comment: "Diagnostic shown when a scene layer fails for an uncategorized reason."
            )
        }
    }
}

/// Diagnostic emitted by the parser when a non-critical field is missing or
/// uses a feature Phase 2.0 does not yet support. Displayed by the UI as
/// secondary text and counted into the capability tier.
struct WPESceneDiagnostic: Equatable, Sendable {
    enum Severity: String, Sendable, Equatable {
        case info
        case warning
    }

    let severity: Severity
    let message: String

    init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}
