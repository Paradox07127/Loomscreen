import CoreGraphics
import Foundation

/// Phase 2.0 minimal model of a Wallpaper Engine `scene.json`. Only the
/// fields that participate in the image-only render pipeline are first-class;
/// the rest become diagnostics so the import service can downgrade the
/// capability tier without losing context.
struct WPESceneDocument: Equatable, Sendable {
    let camera: WPESceneCamera
    let general: WPESceneGeneral
    let imageObjects: [WPESceneImageObject]
    let diagnostics: [WPESceneDiagnostic]

    init(
        camera: WPESceneCamera,
        general: WPESceneGeneral,
        imageObjects: [WPESceneImageObject],
        diagnostics: [WPESceneDiagnostic]
    ) {
        self.camera = camera
        self.general = general
        self.imageObjects = imageObjects
        self.diagnostics = diagnostics
    }
}

/// Camera block — Phase 2.0 keeps the values around for future projection
/// math but the image-only renderer treats the scene as a 2D plane.
struct WPESceneCamera: Equatable, Sendable {
    let center: SIMD3<Double>
    let eye: SIMD3<Double>
    let up: SIMD3<Double>
    let nearZ: Double
    let farZ: Double
    let fov: Double

    static let defaultCamera = WPESceneCamera(
        center: SIMD3<Double>(0, 0, 0),
        eye: SIMD3<Double>(0, 0, 1),
        up: SIMD3<Double>(0, 1, 0),
        nearZ: 0.1,
        farZ: 1000,
        fov: 60
    )
}

/// `general` block. Provides clear color and orthogonal projection size used
/// to size the SKScene canvas.
struct WPESceneGeneral: Equatable, Sendable {
    let clearColor: SIMD3<Double>
    let orthogonalProjection: WPESceneOrthogonalProjection

    static let defaultGeneral = WPESceneGeneral(
        clearColor: SIMD3<Double>(0, 0, 0),
        orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080, auto: true)
    )
}

/// `general.orthogonalprojection`. WPE uses width/height in pixels — used
/// directly as the SKScene size and as the divisor for object origins.
struct WPESceneOrthogonalProjection: Equatable, Sendable {
    let width: Double
    let height: Double
    let auto: Bool
}

/// One renderable image layer. Drives a single SKSpriteNode in the fallback
/// runtime, while preserving WPE material/effect metadata for later renderer
/// phases.
struct WPESceneImageObject: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let imageRelativePath: String
    let materialRelativePath: String?
    let origin: SIMD3<Double>
    let scale: SIMD3<Double>
    let angles: SIMD3<Double>
    let visible: Bool
    let alpha: Double
    let color: SIMD3<Double>
    let brightness: Double
    let blendMode: WPESceneBlendMode
    let alignment: WPESceneAlignment
    /// Explicit pixel dimensions when WPE provided them; otherwise nil and
    /// the runtime falls back to the underlying image size.
    let size: CGSize?
    let effects: [WPESceneImageEffect]
    let animationLayers: [WPESceneAnimationLayer]
    /// Mouse-parallax depth (0 = locked to scene). Phase 2B applies a
    /// conservative UV offset bounded to ±0.05 in built-in copy passes; full
    /// camera-parallax fidelity is deferred until shader translation lands.
    let parallaxDepth: Double

    init(
        id: String,
        name: String,
        imageRelativePath: String,
        materialRelativePath: String?,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        visible: Bool,
        alpha: Double,
        color: SIMD3<Double>,
        brightness: Double,
        blendMode: WPESceneBlendMode,
        alignment: WPESceneAlignment,
        size: CGSize?,
        effects: [WPESceneImageEffect],
        animationLayers: [WPESceneAnimationLayer],
        parallaxDepth: Double = 0
    ) {
        self.id = id
        self.name = name
        self.imageRelativePath = imageRelativePath
        self.materialRelativePath = materialRelativePath
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.visible = visible
        self.alpha = alpha
        self.color = color
        self.brightness = brightness
        self.blendMode = blendMode
        self.alignment = alignment
        self.size = size
        self.effects = effects
        self.animationLayers = animationLayers
        self.parallaxDepth = parallaxDepth
    }
}

struct WPESceneImageEffect: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let fileRelativePath: String
    let visible: Bool
    let passOverrides: [WPESceneEffectPassOverride]

    var isShakeEffect: Bool {
        let normalizedFile = fileRelativePath.lowercased()
        let normalizedName = name.lowercased()
        return normalizedFile.contains("/shake/")
            || normalizedFile.hasSuffix("shake/effect.json")
            || normalizedName == "shake"
    }
}

struct WPESceneEffectPassOverride: Equatable, Sendable {
    let id: Int?
    let combos: [String: Int]
    let constants: [String: WPESceneShaderConstantValue]
    let textures: [Int: String]
}

enum WPESceneShaderConstantValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case vector([Double])

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var vectorValue: [Double]? {
        if case .vector(let value) = self { return value }
        return nil
    }
}

struct WPESceneAnimationLayer: Equatable, Sendable, Identifiable {
    let id: Int
    let rate: Double
    let visible: Bool
    let blend: Double
    let animation: Int
}

enum WPESceneAlignment: String, Equatable, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case top
    case bottom
    case left
    case right

    init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "topleft", "top left":         self = .topLeft
        case "topright", "top right":       self = .topRight
        case "bottomleft", "bottom left":   self = .bottomLeft
        case "bottomright", "bottom right": self = .bottomRight
        case "top":                         self = .top
        case "bottom":                      self = .bottom
        case "left":                        self = .left
        case "right":                       self = .right
        default:                            self = .center
        }
    }
}

/// SKBlendMode passthrough. Names mirror WPE's `blendmode` strings.
enum WPESceneBlendMode: String, Equatable, Sendable {
    case normal
    case translucent
    case additive
    case multiply
    case screen

    init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "translucent": self = .translucent
        case "additive":    self = .additive
        case "multiply":    self = .multiply
        case "screen":      self = .screen
        default:            self = .normal
        }
    }
}
