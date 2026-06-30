import CoreGraphics
import Foundation
import LiveWallpaperCore

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
    /// Original WPE `objects`-array paint order: object id → scene index
    /// (earlier paints behind later). Drives particle/layer z-interleaving.
    public let objectPaintOrder: [String: Int]
    /// Maps each user-property key (the `{"user":K}` envelopes found in
    /// `scene.json`) to the render targets it drives, so a settings change
    /// can be classified as incremental or reload without re-parsing.
    public let propertyBindings: [String: [WPEScenePropertyBinding]]
    /// Parent object id per object (groups included), and each object's OWN baked
    /// `visible`. The renderer walks `objectParentByID` and ANDs each ancestor's
    /// CURRENT visibility (live override if tracked, else `ownVisibilityByID`) into
    /// a layer script's own `visible`, so a script can't show a layer under a
    /// hidden ancestor — and a live ancestor toggle is respected, not snapshotted.
    public let objectParentByID: [String: String]
    public let ownVisibilityByID: [String: Bool]
    public let diagnostics: [WPESceneDiagnostic]

    public init(
        camera: WPESceneCamera,
        general: WPESceneGeneral,
        imageObjects: [WPESceneImageObject],
        particleObjects: [WPESceneParticleObject] = [],
        textObjects: [WPESceneTextObject] = [],
        soundObjects: [WPESceneSoundObject] = [],
        objectPaintOrder: [String: Int] = [:],
        propertyBindings: [String: [WPEScenePropertyBinding]] = [:],
        objectParentByID: [String: String] = [:],
        ownVisibilityByID: [String: Bool] = [:],
        diagnostics: [WPESceneDiagnostic]
    ) {
        self.camera = camera
        self.general = general
        self.imageObjects = imageObjects
        self.particleObjects = particleObjects
        self.textObjects = textObjects
        self.soundObjects = soundObjects
        self.objectPaintOrder = objectPaintOrder
        self.propertyBindings = propertyBindings
        self.objectParentByID = objectParentByID
        self.ownVisibilityByID = ownVisibilityByID
        self.diagnostics = diagnostics
    }
}

/// `action` decides whether changing the property can be patched in place
/// (`.incremental`) or requires a full pipeline reload (`.reload`).
///
/// `condition` carries the expected literal for *condition-form* bindings —
/// `{"user":{"name":K,"condition":"2"},"value":...}` (WPE style selectors).
/// When non-nil the target is visible only while `userValues[propertyKey]`
/// matches `condition`; when nil the property drives the target directly
/// (simple `{"user":K,"value":...}` form).
public struct WPEScenePropertyBinding: Equatable, Sendable {
    public let propertyKey: String
    public let target: WPEScenePropertyBindingTarget
    public let kind: WPEScenePropertyBindingKind
    public let action: WPEScenePropertyBindingAction
    public let condition: String?

    public init(
        propertyKey: String,
        target: WPEScenePropertyBindingTarget,
        kind: WPEScenePropertyBindingKind,
        action: WPEScenePropertyBindingAction,
        condition: String? = nil
    ) {
        self.propertyKey = propertyKey
        self.target = target
        self.kind = kind
        self.action = action
        self.condition = condition
    }
}

public enum WPEScenePropertyBindingTarget: Equatable, Sendable {
    case imageObject(id: String)
    case textObject(id: String)
    case particleObject(id: String)
    case imageEffect(objectID: String, effectID: String)
    case shaderUniform(objectID: String, effectID: String?, passID: Int?, name: String)
    case shaderCombo(objectID: String, effectID: String?, passID: Int?, name: String)
    case textureSlot(objectID: String, effectID: String?, passID: Int?, index: Int)
    case objectResource(objectID: String, field: String)
}

public enum WPEScenePropertyBindingKind: String, Equatable, Sendable {
    case visible
    case color
    case alpha
    case brightness
    case uniform
    case combo
    case texture
    case resource
}

public enum WPEScenePropertyBindingAction: String, Equatable, Sendable {
    case incremental
    case reload
}

/// Consumers ask `requiresReload` first; if false they apply
/// `incrementalBindings` live.
public struct WPEScenePropertyPatch: Equatable, Sendable {
    public let bindingsByProperty: [String: [WPEScenePropertyBinding]]
    public let oldValues: [String: WallpaperEngineProjectPropertyValue]
    public let newValues: [String: WallpaperEngineProjectPropertyValue]
    public let changedKeys: Set<String>

    public init(
        bindingsByProperty: [String: [WPEScenePropertyBinding]],
        oldValues: [String: WallpaperEngineProjectPropertyValue],
        newValues: [String: WallpaperEngineProjectPropertyValue]
    ) {
        self.bindingsByProperty = bindingsByProperty
        self.oldValues = oldValues
        self.newValues = newValues
        let keys = Set(oldValues.keys).union(newValues.keys)
        self.changedKeys = Set(keys.filter { oldValues[$0] != newValues[$0] })
    }

    public var changedBindings: [WPEScenePropertyBinding] {
        changedKeys.sorted().flatMap { bindingsByProperty[$0] ?? [] }
    }

    /// A changed property with no known binding is treated conservatively as
    /// reload, so an unmapped key never silently no-ops.
    public var requiresReload: Bool {
        for key in changedKeys {
            let bindings = bindingsByProperty[key] ?? []
            if bindings.isEmpty { return true }
            if bindings.contains(where: { $0.action == .reload }) { return true }
        }
        return false
    }

    public var incrementalBindings: [WPEScenePropertyBinding] {
        changedBindings.filter { $0.action == .incremental }
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

/// One resolved scriptProperty binding (a WPE SceneScript editor property the
/// scene configures per object — e.g. a clock's `dayFormat`/`showDay`). WPE
/// sliders are numeric, but checkboxes are bools and combos/text are strings.
public enum WPESceneScriptPropertyValue: Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)
}

public struct WPESceneTextObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let text: String
    public let textScript: String?
    /// The scene's per-object scriptProperty overrides (e.g. `dayFormat`,
    /// `showDay`), so the text script renders with the scene's configuration
    /// instead of the script's own declared defaults.
    public let scriptProperties: [String: WPESceneScriptPropertyValue]
    public let fontRelativePath: String?
    public let pointSize: Double
    public let color: SIMD3<Double>
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let visible: Bool
    public let horizontalAlignment: String
    public let verticalAlignment: String
    public let maxWidth: Double?
    /// Per-axis camera-parallax depth (WPE stores this as a Vec2 "x y"). Each
    /// axis scales independently, so "1 0" parallaxes horizontally only and
    /// "0 1" vertically only. `.zero` pins the layer (no parallax).
    public let parallaxDepth: SIMD2<Double>
    /// WPE's authored text-box size in scene pixels (`size`). A WPE text object
    /// is an image layer whose texture is sized to this box; the text fills the
    /// box minus `padding`, then the layer is placed at `origin × scale`. When
    /// nil the renderer falls back to the rasterized text bounds.
    public let boxSize: SIMD2<Double>?
    /// Transparent margin (scene pixels) inside `boxSize` around the text.
    public let padding: Double
    /// WPE 2.8 MSDF text effects (all default to disabled / neutral so 2.7
    /// scenes and the CoreText fallback are unaffected).
    public let outlineSize: Double
    public let outlineColor: SIMD3<Double>
    public let blurSize: Double
    public let shadowSize: Double
    public let shadowColor: SIMD3<Double>
    public let shadowOffset: SIMD2<Double>
    public let letterSpacing: Double

    public init(
        id: String,
        name: String,
        text: String,
        textScript: String? = nil,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:],
        fontRelativePath: String?,
        pointSize: Double,
        color: SIMD3<Double>,
        alpha: Double,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        visible: Bool,
        horizontalAlignment: String,
        verticalAlignment: String,
        maxWidth: Double?,
        parallaxDepth: SIMD2<Double>,
        boxSize: SIMD2<Double>? = nil,
        padding: Double = 0,
        outlineSize: Double = 0,
        outlineColor: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        blurSize: Double = 0,
        shadowSize: Double = 0,
        shadowColor: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        shadowOffset: SIMD2<Double> = SIMD2<Double>(0, 0),
        letterSpacing: Double = 0
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.textScript = textScript
        self.scriptProperties = scriptProperties
        self.fontRelativePath = fontRelativePath
        self.pointSize = pointSize
        self.color = color
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.origin = origin
        self.scale = scale
        self.visible = visible
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment
        self.maxWidth = maxWidth
        self.parallaxDepth = parallaxDepth
        self.boxSize = boxSize
        self.padding = padding
        self.outlineSize = outlineSize
        self.outlineColor = outlineColor
        self.blurSize = blurSize
        self.shadowSize = shadowSize
        self.shadowColor = shadowColor
        self.shadowOffset = shadowOffset
        self.letterSpacing = letterSpacing
    }

    public func resolvedAlpha(at time: Double) -> Double {
        alphaAnimation?.scalar(at: time) ?? alpha
    }

    /// Returns a copy carrying the live (scripted) text + resolved alpha while
    /// preserving every other field — so the renderer's per-frame copy never
    /// drops geometry like `boxSize`/`padding`.
    public func withLiveText(_ liveText: String, alpha liveAlpha: Double) -> WPESceneTextObject {
        WPESceneTextObject(
            id: id,
            name: name,
            text: liveText,
            textScript: textScript,
            scriptProperties: scriptProperties,
            fontRelativePath: fontRelativePath,
            pointSize: pointSize,
            color: color,
            alpha: liveAlpha,
            alphaAnimation: alphaAnimation,
            origin: origin,
            scale: scale,
            visible: visible,
            horizontalAlignment: horizontalAlignment,
            verticalAlignment: verticalAlignment,
            maxWidth: maxWidth,
            parallaxDepth: parallaxDepth,
            boxSize: boxSize,
            padding: padding,
            outlineSize: outlineSize,
            outlineColor: outlineColor,
            blurSize: blurSize,
            shadowSize: shadowSize,
            shadowColor: shadowColor,
            shadowOffset: shadowOffset,
            letterSpacing: letterSpacing
        )
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
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    /// Per-axis camera-parallax depth (WPE stores this as a Vec2 "x y"). Each
    /// axis scales independently, so "1 0" parallaxes horizontally only and
    /// "0 1" vertically only. `.zero` pins the layer (no parallax).
    public let parallaxDepth: SIMD2<Double>
    public let instanceOverride: WPESceneParticleInstanceOverride?

    public init(id: String, name: String, particleRelativePath: String, origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>, visible: Bool, alpha: Double, alphaAnimation: WPESceneAnimatedValue? = nil, color: SIMD3<Double>, parallaxDepth: SIMD2<Double>, instanceOverride: WPESceneParticleInstanceOverride? = nil) {
        self.id = id
        self.name = name
        self.particleRelativePath = particleRelativePath
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.visible = visible
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.color = color
        self.parallaxDepth = parallaxDepth
        self.instanceOverride = instanceOverride
    }

    public func resolvedAlpha(at time: Double) -> Double {
        alphaAnimation?.scalar(at: time) ?? alpha
    }
}

public struct WPESceneParticleInstanceOverride: Equatable, Sendable {
    public let count: Double?
    public let rate: Double?
    public let lifetime: Double?
    public let size: Double?
    public let speed: Double?
    public let alpha: Double?
    /// Override color in the same 0...255 space as particle definitions.
    public let color: SIMD3<Double>?

    public init(
        count: Double? = nil,
        rate: Double? = nil,
        lifetime: Double? = nil,
        size: Double? = nil,
        speed: Double? = nil,
        alpha: Double? = nil,
        color: SIMD3<Double>? = nil
    ) {
        self.count = count
        self.rate = rate
        self.lifetime = lifetime
        self.size = size
        self.speed = speed
        self.alpha = alpha
        self.color = color
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
    public let cameraParallax: WPESceneCameraParallaxSettings
    /// WPE `general.supportsaudioprocessing`: the scene declares audio-reactive
    /// content (a shader/effect samples `g_AudioSpectrum*`). Used by the renderer
    /// to keep the view on the continuous-frame path so the visualizer animates
    /// with audio instead of freezing on the static/on-demand path.
    public let supportsAudioProcessing: Bool

    public init(
        clearColor: SIMD3<Double>,
        orthogonalProjection: WPESceneOrthogonalProjection,
        cameraParallax: WPESceneCameraParallaxSettings = .disabled,
        supportsAudioProcessing: Bool = false
    ) {
        self.clearColor = clearColor
        self.orthogonalProjection = orthogonalProjection
        self.cameraParallax = cameraParallax
        self.supportsAudioProcessing = supportsAudioProcessing
    }

    public static let defaultGeneral = WPESceneGeneral(
        clearColor: SIMD3<Double>(0, 0, 0),
        orthogonalProjection: WPESceneOrthogonalProjection(width: 1920, height: 1080, auto: true)
    )
}

/// WPE scene-level camera parallax: the whole scene follows the cursor, each
/// layer shifting by its `parallaxDepth`. `amount`/`delay`/`mouseInfluence`
/// mirror the WPE general settings; defaults match WPE so an enabled scene that
/// omits them behaves like Wallpaper Engine. Disabled by default (no-op).
public struct WPESceneCameraParallaxSettings: Equatable, Sendable {
    public let enabled: Bool
    public let amount: Double
    public let delay: Double
    public let mouseInfluence: Double

    public init(
        enabled: Bool = false,
        amount: Double = 0.5,
        delay: Double = 0.1,
        mouseInfluence: Double = 0.5
    ) {
        self.enabled = enabled
        self.amount = amount
        self.delay = delay
        self.mouseInfluence = mouseInfluence
    }

    public static let disabled = WPESceneCameraParallaxSettings(
        enabled: false, amount: 0.5, delay: 0.1, mouseInfluence: 0.5
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
    /// Scene object this layer attaches to (the parent puppet for body-split rigs). `nil` for roots.
    public let parentObjectID: String?
    /// Named MDAT anchor on the parent puppet this layer follows (e.g. 头部/脖颈/胸部). `nil` when unattached.
    public let attachment: String?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    /// The object's own (pre-inheritance) transform. `origin`/`scale`/`angles` are parent-baked;
    /// these retain the local values so attachment-following can re-derive the child placement.
    public let localOrigin: SIMD3<Double>
    public let localScale: SIMD3<Double>
    public let localAngles: SIMD3<Double>
    public let visible: Bool
    public let alpha: Double
    public let alphaAnimation: WPESceneAnimatedValue?
    public let color: SIMD3<Double>
    public let brightness: Double
    public let blendMode: WPESceneBlendMode
    public let alignment: WPESceneAlignment
    public let size: CGSize?
    public let dependencies: [String]
    public let effects: [WPESceneImageEffect]
    public let animationLayers: [WPESceneAnimationLayer]
    /// Per-axis camera-parallax depth (WPE stores this as a Vec2 "x y"). Each
    /// axis scales independently, so "1 0" parallaxes horizontally only and
    /// "0 1" vertically only. `.zero` pins the layer (no parallax).
    public let parallaxDepth: SIMD2<Double>
    /// WPE SceneScript attached to this layer's `visible` field (a JS program
    /// with `init()`/`update()` that drives the layer's visibility/alpha and any
    /// video texture). `nil` for the common static-visibility case.
    public let visibleScript: String?
    /// Resolved scriptProperty overrides for `visibleScript` (user-bound values
    /// like `ruchang` overlaid on the script's declared defaults).
    public let scriptProperties: [String: WPESceneScriptPropertyValue]

    public init(
        id: String,
        name: String,
        imageRelativePath: String,
        materialRelativePath: String?,
        parentObjectID: String? = nil,
        attachment: String? = nil,
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>,
        localOrigin: SIMD3<Double>? = nil,
        localScale: SIMD3<Double>? = nil,
        localAngles: SIMD3<Double>? = nil,
        visible: Bool,
        alpha: Double,
        alphaAnimation: WPESceneAnimatedValue? = nil,
        color: SIMD3<Double>,
        brightness: Double,
        blendMode: WPESceneBlendMode,
        alignment: WPESceneAlignment,
        size: CGSize?,
        dependencies: [String] = [],
        effects: [WPESceneImageEffect],
        animationLayers: [WPESceneAnimationLayer],
        parallaxDepth: SIMD2<Double> = SIMD2<Double>(0, 0),
        visibleScript: String? = nil,
        scriptProperties: [String: WPESceneScriptPropertyValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.imageRelativePath = imageRelativePath
        self.materialRelativePath = materialRelativePath
        self.parentObjectID = parentObjectID
        self.attachment = attachment
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.localOrigin = localOrigin ?? origin
        self.localScale = localScale ?? scale
        self.localAngles = localAngles ?? angles
        self.visible = visible
        self.alpha = alpha
        self.alphaAnimation = alphaAnimation
        self.color = color
        self.brightness = brightness
        self.blendMode = blendMode
        self.alignment = alignment
        self.size = size
        self.dependencies = dependencies
        self.effects = effects
        self.animationLayers = animationLayers
        self.parallaxDepth = parallaxDepth
        self.visibleScript = visibleScript
        self.scriptProperties = scriptProperties
    }

    public func resolvedAlpha(at time: Double) -> Double {
        alphaAnimation?.scalar(at: time) ?? alpha
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

public struct WPESceneAnimationKeyframe: Equatable, Sendable {
    public let frame: Double
    public let value: Double

    public init(frame: Double, value: Double) {
        self.frame = frame
        self.value = value
    }
}

public struct WPESceneNumericAnimation: Equatable, Sendable {
    public let tracks: [[WPESceneAnimationKeyframe]]
    public let fps: Double
    public let length: Double
    public let mode: String
    public let wrapLoop: Bool

    public init(
        tracks: [[WPESceneAnimationKeyframe]],
        fps: Double,
        length: Double,
        mode: String,
        wrapLoop: Bool
    ) {
        self.tracks = tracks.map { $0.sorted { $0.frame < $1.frame } }
        self.fps = fps > 0 ? fps : 30
        self.length = max(0, length)
        self.mode = mode.lowercased()
        self.wrapLoop = wrapLoop
    }

    public func values(at time: Double, fallbacks: [Double]) -> [Double] {
        guard !tracks.isEmpty else { return fallbacks }
        let frame = effectiveFrame(at: time)
        return tracks.enumerated().map { index, track in
            value(in: track, atFrame: frame, fallback: fallbacks[safe: index] ?? fallbacks.first ?? 0)
        }
    }

    private func effectiveFrame(at time: Double) -> Double {
        let rawFrame = max(0, time) * fps
        if shouldLoop, length > 0 {
            let wrapped = rawFrame.truncatingRemainder(dividingBy: length)
            return wrapped >= 0 ? wrapped : wrapped + length
        }
        let lastTrackFrame = tracks
            .compactMap(\.last?.frame)
            .max() ?? 0
        let clampFrame = length > 0 ? max(length, lastTrackFrame) : lastTrackFrame
        return min(max(rawFrame, 0), clampFrame)
    }

    private var shouldLoop: Bool {
        wrapLoop || mode == "loop" || mode == "mirror"
    }

    private func value(
        in track: [WPESceneAnimationKeyframe],
        atFrame frame: Double,
        fallback: Double
    ) -> Double {
        guard let first = track.first else { return fallback }
        if frame <= first.frame { return first.value }
        guard let last = track.last else { return first.value }
        if frame >= last.frame { return last.value }

        for index in 0..<(track.count - 1) {
            let start = track[index]
            let end = track[index + 1]
            guard frame >= start.frame && frame <= end.frame else { continue }
            let span = max(end.frame - start.frame, 0.0001)
            let t = min(max((frame - start.frame) / span, 0), 1)
            return start.value + (end.value - start.value) * t
        }
        return last.value
    }
}

public struct WPESceneAnimatedValue: Equatable, Sendable {
    public let animation: WPESceneNumericAnimation
    public let scalarFallback: Double?
    public let vectorFallback: [Double]?

    public init(
        animation: WPESceneNumericAnimation,
        scalarFallback: Double?,
        vectorFallback: [Double]?
    ) {
        self.animation = animation
        self.scalarFallback = scalarFallback
        self.vectorFallback = vectorFallback
    }

    public func resolvedValue(at time: Double) -> WPESceneShaderConstantValue {
        if let vectorFallback, animation.tracks.count > 1 {
            return .vector(animation.values(at: time, fallbacks: vectorFallback))
        }
        return .number(scalar(at: time) ?? scalarFallback ?? 0)
    }

    public func scalar(at time: Double) -> Double? {
        let fallback = scalarFallback ?? vectorFallback?.first ?? 0
        return animation.values(at: time, fallbacks: [fallback]).first
    }

    public func vector(at time: Double) -> [Double]? {
        guard let vectorFallback else {
            return scalar(at: time).map { [$0] }
        }
        return animation.values(at: time, fallbacks: vectorFallback)
    }
}

public enum WPESceneShaderConstantValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case vector([Double])
    case animated(WPESceneAnimatedValue)

    public var numberValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .animated(let value):
            return value.scalar(at: 0)
        default:
            return nil
        }
    }

    public var vectorValue: [Double]? {
        switch self {
        case .vector(let value):
            return value
        case .animated(let value):
            return value.vector(at: 0)
        default:
            return nil
        }
    }

    public func resolved(at time: Double) -> WPESceneShaderConstantValue {
        if case .animated(let value) = self {
            return value.resolvedValue(at: time)
        }
        return self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public struct WPESceneAnimationLayer: Equatable, Sendable, Identifiable {
    public let id: Int
    public let rate: Double
    public let visible: Bool
    public let blend: Double
    public let animation: Int
    /// Composed ADDITIVELY on top of the base (non-additive) layer — e.g. a
    /// blink/face layer over an idle-sway base. Drives multi-layer palette blending.
    public let additive: Bool

    public init(id: Int, rate: Double, visible: Bool, blend: Double, animation: Int, additive: Bool = false) {
        self.id = id
        self.rate = rate
        self.visible = visible
        self.blend = blend
        self.animation = animation
        self.additive = additive
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
