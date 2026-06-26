import Foundation

public enum WallpaperContent: Equatable, Sendable {
    /// - `bookmarkData` resolves to a plain video file when `packageEntryName`
    ///   is `nil` (loose / legacy imports), or to a `scene.pkg` when it is set
    ///   (in-place packaged video). For the package case the player serves the
    ///   entry via a resource loader windowed into the package — no extraction.
    case video(bookmarkData: Data, packageEntryName: String?)
    case html(source: HTMLSource, config: HTMLConfig)
    case metalShader(ShaderSource)
    case scene(SceneDescriptor)

    public static func video(bookmarkData: Data) -> WallpaperContent {
        .video(bookmarkData: bookmarkData, packageEntryName: nil)
    }

    public var wallpaperType: WallpaperType {
        switch self {
        case .video:
            return .video
        case .html:
            return .html
        case .metalShader:
            return .metalShader
        case .scene:
            return .scene
        }
    }

    public var activeVideoBookmarkData: Data? {
        guard case .video(let bookmarkData, _) = self else { return nil }
        return bookmarkData
    }

    /// The `scene.pkg` entry name when this is an in-place packaged video,
    /// else `nil` (loose video file).
    public var packageVideoEntryName: String? {
        guard case .video(_, let entryName) = self else { return nil }
        return entryName
    }

    public var htmlSource: HTMLSource? {
        guard case .html(let source, _) = self else { return nil }
        return source
    }

    public var htmlConfig: HTMLConfig? {
        guard case .html(_, let config) = self else { return nil }
        return config
    }

    public var shaderSource: ShaderSource? {
        guard case .metalShader(let source) = self else { return nil }
        return source
    }

    /// Returns `nil` when a custom shader is active (for UI surfaces that only
    /// care about the builtin preset, e.g. the icon-grid selector).
    public var shaderPreset: MetalShaderPreset? {
        shaderSource?.builtinPreset
    }

    public var sceneDescriptor: SceneDescriptor? {
        guard case .scene(let descriptor) = self else { return nil }
        return descriptor
    }
}

// MARK: - Codable

extension WallpaperContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case video, html, metalShader, scene
    }

    private enum VideoCodingKeys: String, CodingKey {
        case bookmarkData
        case packageEntryName
    }

    private enum HTMLCodingKeys: String, CodingKey {
        case source
        case config
        case legacyString = "_0"   // legacy single-string payload
    }

    private enum ShaderCodingKeys: String, CodingKey {
        case preset = "_0"
    }

    private enum SceneCodingKeys: String, CodingKey {
        case descriptor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let videoNested = try? container.nestedContainer(keyedBy: VideoCodingKeys.self, forKey: .video) {
            let bookmark = try videoNested.decode(Data.self, forKey: .bookmarkData)
            // Absent in legacy payloads → loose video file.
            let packageEntryName = try videoNested.decodeIfPresent(String.self, forKey: .packageEntryName)
            self = .video(bookmarkData: bookmark, packageEntryName: packageEntryName)
            return
        }

        if let htmlNested = try? container.nestedContainer(keyedBy: HTMLCodingKeys.self, forKey: .html) {
            if let source = try? htmlNested.decode(HTMLSource.self, forKey: .source) {
                let config = try htmlNested.decodeIfPresent(HTMLConfig.self, forKey: .config) ?? HTMLConfig()
                self = .html(source: source, config: config)
                return
            }
            if let legacyString = try? htmlNested.decode(String.self, forKey: .legacyString) {
                self = .html(source: HTMLSource(legacyString: legacyString), config: HTMLConfig())
                return
            }
        }

        if let shaderNested = try? container.nestedContainer(keyedBy: ShaderCodingKeys.self, forKey: .metalShader) {
            // ShaderSource's Codable handles both the legacy bare-string form
            // (`"_0": "Waves"`) and the new tagged form
            // (`"_0": {"builtin": "Waves"}` / `{"custom": "<uuid>"}`).
            let source = try shaderNested.decode(ShaderSource.self, forKey: .preset)
            self = .metalShader(source)
            return
        }

        if let sceneNested = try? container.nestedContainer(keyedBy: SceneCodingKeys.self, forKey: .scene) {
            let descriptor = try sceneNested.decode(SceneDescriptor.self, forKey: .descriptor)
            self = .scene(descriptor)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "WallpaperContent decode failed: no recognised case in container"
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .video(let bookmarkData, let packageEntryName):
            var nested = container.nestedContainer(keyedBy: VideoCodingKeys.self, forKey: .video)
            try nested.encode(bookmarkData, forKey: .bookmarkData)
            try nested.encodeIfPresent(packageEntryName, forKey: .packageEntryName)
        case .html(let source, let config):
            var nested = container.nestedContainer(keyedBy: HTMLCodingKeys.self, forKey: .html)
            try nested.encode(source, forKey: .source)
            try nested.encode(config, forKey: .config)
        case .metalShader(let source):
            var nested = container.nestedContainer(keyedBy: ShaderCodingKeys.self, forKey: .metalShader)
            try nested.encode(source, forKey: .preset)
        case .scene(let descriptor):
            var nested = container.nestedContainer(keyedBy: SceneCodingKeys.self, forKey: .scene)
            try nested.encode(descriptor, forKey: .descriptor)
        }
    }
}
