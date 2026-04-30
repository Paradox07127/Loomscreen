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
