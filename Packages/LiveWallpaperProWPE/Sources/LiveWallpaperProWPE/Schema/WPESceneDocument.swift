import CoreGraphics
import Foundation

/// Phase 2.0 minimal model of a Wallpaper Engine `scene.json`. Only the
/// fields that participate in the image-only render pipeline are first-class;
/// the rest become diagnostics so the import service can downgrade the
/// capability tier without losing context.
public struct WPESceneDocument: Equatable, Sendable {
    public let camera: WPESceneCamera
    public let general: WPESceneGeneral
    public let imageObjects: [WPESceneImageObject]
    public let particleObjects: [WPESceneParticleObject]
    public let textObjects: [WPESceneTextObject]
    public let soundObjects: [WPESceneSoundObject]
    public let diagnostics: [WPESceneDiagnostic]

    public init(
        camera: WPESceneCamera,
        general: WPESceneGeneral,
        imageObjects: [WPESceneImageObject],
        particleObjects: [WPESceneParticleObject] = [],
        textObjects: [WPESceneTextObject] = [],
        soundObjects: [WPESceneSoundObject] = [],
        diagnostics: [WPESceneDiagnostic]
    ) {
        self.camera = camera
        self.general = general
        self.imageObjects = imageObjects
        self.particleObjects = particleObjects
        self.textObjects = textObjects
        self.soundObjects = soundObjects
        self.diagnostics = diagnostics
    }
}

public struct WPESceneSoundObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let soundRelativePaths: [String]
    public let volume: Double
    public let playbackMode: String
    public let startSilent: Bool

    public init(id: String, name: String, soundRelativePaths: [String], volume: Double, playbackMode: String, startSilent: Bool) {
        self.id = id
        self.name = name
        self.soundRelativePaths = soundRelativePaths
        self.volume = volume
        self.playbackMode = playbackMode
        self.startSilent = startSilent
    }
}

public struct WPESceneTextObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let text: String
    public let textScript: String?
    public let fontRelativePath: String?
    public let pointSize: Double
    public let color: SIMD3<Double>
    public let alpha: Double
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let visible: Bool
    public let horizontalAlignment: String
    public let verticalAlignment: String
    public let maxWidth: Double?
    public let parallaxDepth: Double

    public init(
        id: String,
        name: String,
        text: String,
        textScript: String? = nil,
        fontRelativePath: String?,
        pointSize: Double,
        color: SIMD3<Double>,
        alpha: Double,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        visible: Bool,
        horizontalAlignment: String,
        verticalAlignment: String,
        maxWidth: Double?,
        parallaxDepth: Double
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.textScript = textScript
        self.fontRelativePath = fontRelativePath
        self.pointSize = pointSize
        self.color = color
        self.alpha = alpha
        self.origin = origin
        self.scale = scale
        self.visible = visible
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.maxWidth = maxWidth
        self.parallaxDepth = parallaxDepth
    }
}

public struct WPESceneParticleObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let particleRelativePath: String
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let visible: Bool
    public let alpha: Double
    public let color: SIMD3<Double>
    public let parallaxDepth: Double

    public init(id: String, name: String, particleRelativePath: String, origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>, visible: Bool, alpha: Double, color: SIMD3<Double>, parallaxDepth: Double) {
        self.id = id
        self.name = name
        self.particleRelativePath = particleRelativePath
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.visible = visible
        self.alpha = alpha
        self.color = color
        self.parallaxDepth = parallaxDepth
    }
}

public struct WPESceneCamera: Equatable, Sendable {
    public let center: SIMD3<Double>
    public let eye: SIMD3<Double>
    public let up: SIMD3<Double>
    public let nearZ: Double
    public let farZ: Double
    public let fov: Double

    public init(center: SIMD3<Double>, eye: SIMD3<Double>, up: SIMD3<Double>, nearZ: Double, farZ: Double, fov: Double) {
        self.center = center
        self.eye = eye
        self.up = up
        self.nearZ = nearZ
        self.farZ = farZ
        self.fov = fov
    }

    public static let defaultCamera = WPESceneCamera(
        center: SIMD3<Double>(0, 0, 0),
        eye: SIMD3<Double>(0, 0, 1),
        up: SIMD3<Double>(0, 1, 0),
        nearZ: 0.1,
        farZ: 1000,
        fov: 60
    )
}

public struct WPESceneGeneral: Equatable, Sendable {
    public let clearColor: SIMD3<Double>
    public let orthogonalProjection: WPESceneOrthogonalProjection

    public init(clearColor: SIMD3<Double>, orthogonalProjection: WPESceneOrthogonalProjection) {
        self.clearColor = clearColor
        self.orthogonalProjection = orthogonalProjection
    }

    public static let defaultGeneral = WPESceneGeneral(
        clearColor: SIMD3<Double>(0, 0, 0),
        orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080, auto: true)
    )
}

public struct WPESceneOrthogonalProjection: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let auto: Bool

    public init(width: Double, height: Double, auto: Bool) {
        self.width = width
        self.height = height
        self.auto = auto
    }
}

public struct WPESceneImageObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imageRelativePath: String
    public let materialRelativePath: String?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let visible: Bool
    public let alpha: Double
    public let color: SIMD3<Double>
    public let brightness: Double
    public let blendMode: WPESceneBlendMode
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    public let effects: [WPESceneImageEffect]
    public let animationLayers: [WPESceneAnimationLayer]
    public let parallaxDepth: Double

    public init(
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

public struct WPESceneImageEffect: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let fileRelativePath: String
    public let visible: Bool
    public let passOverrides: [WPESceneEffectPassOverride]

    public init(id: String, name: String, fileRelativePath: String, visible: Bool, passOverrides: [WPESceneEffectPassOverride]) {
        self.id = id
        self.name = name
        self.fileRelativePath = fileRelativePath
        self.visible = visible
        self.passOverrides = passOverrides
    }

    public var isShakeEffect: Bool {
        let normalizedFile = fileRelativePath.lowercased()
        let normalizedName = name.lowercased()
        return normalizedFile.contains("/shake/")
            || normalizedFile.hasSuffix("shake/effect.json")
            || normalizedName == "shake"
    }
}

public struct WPESceneEffectPassOverride: Equatable, Sendable {
    public let id: Int?
    public let combos: [String: Int]
    public let constants: [String: WPESceneShaderConstantValue]
    public let textures: [Int: String]

    public init(id: Int?, combos: [String: Int], constants: [String: WPESceneShaderConstantValue], textures: [Int: String]) {
        self.id = id
        self.combos = combos
        self.constants = constants
        self.textures = textures
    }
}

public enum WPESceneShaderConstantValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case vector([Double])

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var vectorValue: [Double]? {
        if case .vector(let value) = self { return value }
        return nil
    }
}

public struct WPESceneAnimationLayer: Equatable, Sendable, Identifiable {
    public let id: Int
    public let rate: Double
    public let visible: Bool
    public let blend: Double
    public let animation: Int

    public init(id: Int, rate: Double, visible: Bool, blend: Double, animation: Int) {
        self.id = id
        self.rate = rate
        self.visible = visible
        self.blend = blend
        self.animation = animation
    }
}

public enum WPESceneAlignment: String, Equatable, Sendable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case top
    case bottom
    case left
    case right

    public init(rawWPEValue raw: String?) {
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

public enum WPESceneBlendMode: String, Equatable, Sendable {
    case normal
    case translucent
    case additive
    case multiply
    case screen

    public init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "translucent": self = .translucent
        case "additive":    self = .additive
        case "multiply":    self = .multiply
        case "screen":      self = .screen
        default:            self = .normal
        }
    }
}
