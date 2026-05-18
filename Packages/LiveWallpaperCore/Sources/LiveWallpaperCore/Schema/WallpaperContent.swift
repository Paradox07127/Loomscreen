import Foundation

public enum WallpaperContent: Equatable, Sendable {
    case video(bookmarkData: Data)
    case html(source: HTMLSource, config: HTMLConfig)
    case metalShader(MetalShaderPreset)
    case scene(SceneDescriptor)

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
        guard case .video(let bookmarkData) = self else { return nil }
        return bookmarkData
    }

    public var htmlSource: HTMLSource? {
        guard case .html(let source, _) = self else { return nil }
        return source
    }

    public var htmlConfig: HTMLConfig? {
        guard case .html(_, let config) = self else { return nil }
        return config
    }

    public var shaderPreset: MetalShaderPreset? {
        guard case .metalShader(let preset) = self else { return nil }
        return preset
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
            self = .video(bookmarkData: bookmark)
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
            let preset = try shaderNested.decode(MetalShaderPreset.self, forKey: .preset)
            self = .metalShader(preset)
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
        case .video(let bookmarkData):
            var nested = container.nestedContainer(keyedBy: VideoCodingKeys.self, forKey: .video)
            try nested.encode(bookmarkData, forKey: .bookmarkData)
        case .html(let source, let config):
            var nested = container.nestedContainer(keyedBy: HTMLCodingKeys.self, forKey: .html)
            try nested.encode(source, forKey: .source)
            try nested.encode(config, forKey: .config)
        case .metalShader(let preset):
            var nested = container.nestedContainer(keyedBy: ShaderCodingKeys.self, forKey: .metalShader)
            try nested.encode(preset, forKey: .preset)
        case .scene(let descriptor):
            var nested = container.nestedContainer(keyedBy: SceneCodingKeys.self, forKey: .scene)
            try nested.encode(descriptor, forKey: .descriptor)
        }
    }
}
