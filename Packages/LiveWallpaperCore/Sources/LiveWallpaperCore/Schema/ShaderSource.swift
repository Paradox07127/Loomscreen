import Foundation

/// What a shader wallpaper is sourcing its fragment math from. Sum type so
/// builtin presets and user-imported shaders flow through the same path
/// without forcing every call site to switch between two separate fields.
///
/// `Codable` is backward-compatible: an older config blob storing a bare
/// `MetalShaderPreset` rawValue (e.g. `"Waves"`) at the `metalShader.preset`
/// position still decodes as `.builtin(.waves)`. New configs encode as a
/// tagged container `{"builtin": "Waves"}` or `{"custom": "<uuid>"}`.
public enum ShaderSource: Equatable, Sendable, Hashable {
    case builtin(MetalShaderPreset)
    case custom(UUID)

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    public var builtinPreset: MetalShaderPreset? {
        if case .builtin(let preset) = self { return preset }
        return nil
    }

    public var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }
}

extension ShaderSource {
    /// Builtin shorthands so call sites and tests can keep writing the
    /// preset case directly — `.metalShader(.aurora)` resolves to
    /// `.metalShader(.builtin(.aurora))` via Swift's type inference.
    public static let waves: ShaderSource    = .builtin(.waves)
    public static let plasma: ShaderSource   = .builtin(.plasma)
    public static let gradient: ShaderSource = .builtin(.gradient)
    public static let noise: ShaderSource    = .builtin(.noise)
    public static let aurora: ShaderSource   = .builtin(.aurora)
}

extension ShaderSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case builtin
        case custom
    }

    public init(from decoder: Decoder) throws {
        // Legacy path: bare `MetalShaderPreset` rawValue at this position.
        // Earlier `WallpaperContent` encoded the preset directly as a single
        // string value at `metalShader._0`, so a config from before this
        // change still decodes through the single-value-container fallback.
        if let single = try? decoder.singleValueContainer().decode(MetalShaderPreset.self) {
            self = .builtin(single)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let preset = try container.decodeIfPresent(MetalShaderPreset.self, forKey: .builtin) {
            self = .builtin(preset)
            return
        }
        if let id = try container.decodeIfPresent(UUID.self, forKey: .custom) {
            self = .custom(id)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "ShaderSource decode failed: container had neither builtin nor custom"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let preset):
            try container.encode(preset, forKey: .builtin)
        case .custom(let id):
            try container.encode(id, forKey: .custom)
        }
    }
}
