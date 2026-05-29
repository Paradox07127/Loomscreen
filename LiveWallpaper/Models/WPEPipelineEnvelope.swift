#if !LITE_BUILD
import CoreGraphics
import Foundation

/// JSON contract between Swift and the embedded WebGL2 runtime.
struct WPEPipelineEnvelope: Codable, Sendable {
    static let currentVersion = 1

    var version: Int = WPEPipelineEnvelope.currentVersion
    var sceneID: String
    var sceneTitle: String?
    var assetScheme: WPEAssetSchemeBinding
    var renderGraph: WPERenderGraphPayload?

    init(
        sceneID: String,
        sceneTitle: String? = nil,
        assetScheme: WPEAssetSchemeBinding,
        renderGraph: WPERenderGraphPayload? = nil
    ) {
        self.sceneID = sceneID
        self.sceneTitle = sceneTitle
        self.assetScheme = assetScheme
        self.renderGraph = renderGraph
    }

    enum CodingKeys: String, CodingKey {
        case version
        case sceneID = "scene_id"
        case sceneTitle = "scene_title"
        case assetScheme = "asset_scheme"
        case renderGraph = "render_graph"
    }
}

struct WPEAssetSchemeBinding: Codable, Sendable {
    /// Per-session nonce embedded in `wpe-asset://scene/<nonce>/...` URLs.
    /// JS must use this exact nonce when constructing asset requests; the
    /// scheme handler rejects mismatches so a stale URL retained by a
    /// previous scene cannot replay against the active session.
    var nonce: String
    /// Pre-rendered prefix the JS side concatenates with relative paths.
    /// Saves the runtime from reconstructing scheme + host + nonce.
    var urlPrefix: String

    enum CodingKeys: String, CodingKey {
        case nonce
        case urlPrefix = "url_prefix"
    }
}

struct WPERenderGraphPayload: Codable, Sendable {
    var layers: [WPERenderLayerPayload]
    var sceneSize: WPESceneSizePayload
    var orthogonalProjection: WPEOrthogonalProjectionPayload

    init(
        prepared: WPEPreparedRenderPipeline,
        sceneSize: CGSize,
        projection: WPESceneOrthogonalProjection
    ) {
        self.layers = prepared.layers.map(WPERenderLayerPayload.init(prepared:))
        self.sceneSize = WPESceneSizePayload(width: sceneSize.width, height: sceneSize.height)
        self.orthogonalProjection = WPEOrthogonalProjectionPayload(projection)
    }

    enum CodingKeys: String, CodingKey {
        case layers
        case sceneSize = "scene_size"
        case orthogonalProjection = "orthogonal_projection"
    }
}

struct WPERenderLayerPayload: Codable, Sendable {
    var objectID: String
    var objectName: String
    var imagePath: String
    var materialPath: String?
    var geometry: WPERenderLayerGeometryPayload
    var compositeA: String
    var compositeB: String
    var parallaxDepth: Double
    var localFBOs: [WPERenderFBOPayload]
    var passes: [WPERenderPassPayload]

    init(prepared: WPEPreparedRenderLayer) {
        let layer = prepared.graphLayer
        self.objectID = layer.objectID
        self.objectName = layer.objectName
        self.imagePath = layer.imagePath
        self.materialPath = layer.materialPath
        self.geometry = WPERenderLayerGeometryPayload(layer.geometry)
        self.compositeA = layer.compositeA
        self.compositeB = layer.compositeB
        self.parallaxDepth = layer.parallaxDepth
        self.localFBOs = layer.localFBOs.map(WPERenderFBOPayload.init(_:))
        self.passes = prepared.passes.map(WPERenderPassPayload.init(prepared:))
    }

    enum CodingKeys: String, CodingKey {
        case objectID = "object_id"
        case objectName = "object_name"
        case imagePath = "image_path"
        case materialPath = "material_path"
        case geometry
        case compositeA = "composite_a"
        case compositeB = "composite_b"
        case parallaxDepth = "parallax_depth"
        case localFBOs = "local_fbos"
        case passes
    }
}

struct WPERenderLayerGeometryPayload: Codable, Sendable {
    var origin: WPEVector3Payload
    var scale: WPEVector3Payload
    var angles: WPEVector3Payload
    var alignment: String
    var size: WPESceneSizePayload?
    var alpha: Double
    var color: WPEVector3Payload
    var brightness: Double

    init(_ geometry: WPERenderLayerGeometry) {
        self.origin = WPEVector3Payload(geometry.origin)
        self.scale = WPEVector3Payload(geometry.scale)
        self.angles = WPEVector3Payload(geometry.angles)
        self.alignment = geometry.alignment.rawValue
        self.size = geometry.size.map { WPESceneSizePayload(width: $0.width, height: $0.height) }
        self.alpha = geometry.alpha
        self.color = WPEVector3Payload(geometry.color)
        self.brightness = geometry.brightness
    }
}

struct WPEVector3Payload: Codable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    init(_ value: SIMD3<Double>) {
        self.x = value.x
        self.y = value.y
        self.z = value.z
    }
}

struct WPERenderPassPayload: Codable, Sendable {
    var id: String
    var shaderName: String
    var vertexSource: String
    var fragmentSource: String
    var isBuiltin: Bool
    var target: WPERenderTargetPayload
    var source: WPETextureReferencePayload
    var textures: [Int: WPETextureReferencePayload]
    var binds: [Int: WPETextureReferencePayload]
    var constants: [String: WPEConstantValuePayload]
    var combos: [String: Int]
    var blending: String
    var cullMode: String
    var depthTest: String
    var depthWrite: String

    init(prepared: WPEPreparedRenderPass) {
        let pass = prepared.pass
        let shader = prepared.shader
        self.id = pass.id
        self.shaderName = shader?.name ?? pass.shader
        self.vertexSource = shader?.vertexSource ?? ""
        self.fragmentSource = shader?.fragmentSource ?? ""
        self.isBuiltin = shader?.isBuiltin ?? false
        self.target = WPERenderTargetPayload(pass.target)
        self.source = WPETextureReferencePayload(pass.source)
        self.textures = prepared.textureBindings.mapValues(WPETextureReferencePayload.init(_:))
        self.binds = pass.binds.mapValues(WPETextureReferencePayload.init(_:))
        self.constants = prepared.uniformValues.mapValues(WPEConstantValuePayload.init(_:))
        self.combos = prepared.comboValues
        self.blending = pass.blending
        self.cullMode = pass.cullMode
        self.depthTest = pass.depthTest
        self.depthWrite = pass.depthWrite
    }

    enum CodingKeys: String, CodingKey {
        case id
        case shaderName = "shader_name"
        case vertexSource = "vertex_source"
        case fragmentSource = "fragment_source"
        case isBuiltin = "is_builtin"
        case target
        case source
        case textures
        case binds
        case constants
        case combos
        case blending
        case cullMode = "cull_mode"
        case depthTest = "depth_test"
        case depthWrite = "depth_write"
    }
}

struct WPERenderFBOPayload: Codable, Sendable {
    var name: String
    var scale: Double
    var format: String
    var unique: Bool

    init(_ fbo: WPERenderFBO) {
        self.name = fbo.name
        self.scale = fbo.scale
        self.format = fbo.format
        self.unique = fbo.unique
    }
}

struct WPERenderTargetPayload: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case scene
        case fbo
        case layerComposite = "layer_composite"
    }

    var kind: Kind
    var name: String?

    init(_ target: WPERenderTarget) {
        switch target {
        case .scene:
            self.kind = .scene
            self.name = nil
        case .fbo(let name):
            self.kind = .fbo
            self.name = name
        case .layerComposite(let name):
            self.kind = .layerComposite
            self.name = name
        }
    }
}

struct WPETextureReferencePayload: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case asset
        case fbo
        case previous
    }

    var kind: Kind
    var value: String?

    init(_ reference: WPETextureReference) {
        switch reference {
        case .image(let value):
            self.kind = .image
            self.value = value
        case .asset(let value):
            self.kind = .asset
            self.value = value
        case .fbo(let value):
            self.kind = .fbo
            self.value = value
        case .previous:
            self.kind = .previous
            self.value = nil
        }
    }
}

enum WPEConstantValuePayload: Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case vector([Double])

    init(_ value: WPESceneShaderConstantValue) {
        switch value {
        case .bool(let bool):
            self = .bool(bool)
        case .number(let number):
            self = .number(number)
        case .string(let string):
            self = .string(string)
        case .vector(let vector):
            self = .vector(vector)
        case .animated(let animated):
            self.init(animated.resolvedValue(at: 0))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case bool
        case number
        case string
        case vector
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .vector:
            self = .vector(try container.decode([Double].self, forKey: .value))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .vector(let value):
            try container.encode(Kind.vector, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

struct WPESceneSizePayload: Codable, Sendable {
    var width: Double
    var height: Double
}

struct WPEOrthogonalProjectionPayload: Codable, Sendable {
    var width: Int
    var height: Int

    init(_ projection: WPESceneOrthogonalProjection) {
        self.width = max(Int(projection.width.rounded()), 1)
        self.height = max(Int(projection.height.rounded()), 1)
    }
}

// MARK: - Bridge messages

enum WPEWebGLIncomingEvent: String, Codable, Sendable {
    case ready
    case sceneLoaded = "scene_loaded"
    case loadFailed = "load_failed"
    case error
    case diagnostic
    case frame
    case readback
}

struct WPEWebGLIncomingMessage: Decodable, Sendable {
    var event: WPEWebGLIncomingEvent
    var sceneID: String?
    var stage: String?
    var passID: String?
    var message: String?
    var frameIndex: Int?
    var elapsedMs: Double?
    var kind: String?
    var width: Int?
    var height: Int?
    var dataBase64: String?

    enum CodingKeys: String, CodingKey {
        case event
        case sceneID = "scene_id"
        case stage
        case passID = "pass_id"
        case message
        case frameIndex = "frame_index"
        case elapsedMs = "elapsed_ms"
        case kind
        case width
        case height
        case dataBase64 = "data_b64"
    }
}

struct WPERuntimeStatePayload: Encodable, Sendable {
    /// Optional — when nil, the JS runtime keeps using its own
    /// `performance.now()`-based clock. Pushing a non-nil value here
    /// pins JS-side `g_Time` to whatever Swift dictates and freezes
    /// shader animation until the next push, which is rarely the
    /// caller's intent. Both lifecycle pushes (`setThrottled`,
    /// `applyPerformanceProfile`) leave this nil.
    var time: Double?
    var pointer: SIMDPoint?
    var audioSpectrum: [Float]?
    var visibility: WPEVisibility?

    struct SIMDPoint: Encodable, Sendable {
        var x: Double
        var y: Double
        var click: Double
        var hover: Double
    }

    enum WPEVisibility: String, Encodable, Sendable {
        case active
        case occluded
        case background
    }
}
#endif
