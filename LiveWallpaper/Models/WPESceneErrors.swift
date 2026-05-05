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
            return "scene.json is not valid UTF-8."
        case .rootNotObject:
            return "scene.json must be a JSON object at the root."
        case .missingCamera:
            return "scene.json is missing the required camera block."
        case .missingGeneral:
            return "scene.json is missing the required general block."
        case .malformedField(let field):
            return "scene.json field \(field) is malformed."
        }
    }
}

/// Failure modes that surface from the SpriteKit runtime layer when a parsed
/// scene cannot be staged. These are observed by the UI state machine and
/// mapped to `FallbackReason` so the user gets a specific message rather than
/// a generic "scene failed to load".
enum SceneRenderingError: Error, LocalizedError, Equatable, Sendable {
    case cacheRootMissing
    case entryFileMissing(String)
    case parseFailed(String)
    case unsupportedShader
    case noRenderableObjects
    /// Every layer hit a resource-level failure (decode / missing / unsupported
    /// format / etc.). The associated diagnostic carries the *first* such
    /// failure we encountered so the UI can surface a precise reason instead
    /// of a generic "no renderable objects" message.
    case resourceFailed(SceneLoadDiagnostic)

    var errorDescription: String? {
        switch self {
        case .cacheRootMissing:
            return "Scene cache directory is missing."
        case .entryFileMissing(let entry):
            return "Scene entry file \(entry) was not found in the cache."
        case .parseFailed(let detail):
            return "Failed to parse scene.json: \(detail)"
        case .unsupportedShader:
            return "Scene uses unsupported shader features."
        case .noRenderableObjects:
            return "Scene has no renderable image layers."
        case .resourceFailed(let diagnostic):
            return diagnostic.errorDescription
        }
    }
}

/// Per-layer failure recorded by `SceneRenderingController.load()`. Phase 2.1
/// uses this to (a) decide whether the scene mounts in degraded mode (≥1
/// layer renders) or fails outright, and (b) surface a concrete reason in
/// the developer diagnostic panel and the fallback card.
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
            return "The image for '\(layer)' couldn't be loaded."
        case .legacyUnsupportedTexture(let layer):
            return "The image format used by '\(layer)' is no longer supported."
        case .fileMissing(let layer, _):
            return "A file required by the '\(layer)' layer is missing."
        case .crossPackageReference(let layer, _):
            return "The layer '\(layer)' requires files from an external package, which is not supported."
        case .materialUnresolved(let layer, _):
            return "A rendering feature needed by '\(layer)' is not supported yet."
        case .other(let layer, let message):
            return "The layer '\(layer)' encountered an issue: \(message)."
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
