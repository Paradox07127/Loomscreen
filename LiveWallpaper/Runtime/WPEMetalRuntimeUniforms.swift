#if !LITE_BUILD
import AppKit
import Foundation
import QuartzCore
import simd

/// Per-frame, smoothed camera-parallax state. `smoothed` is the cursor offset
/// from screen center (−0.5…0.5 per axis) after exponential smoothing and the
/// scene's amount/mouse-influence calibration. `pixelOffset` turns it into a
/// per-layer scene-pixel translation scaled by that layer's `parallaxDepth`.
struct WPECameraParallaxFrame: Equatable, Sendable {
    var smoothed: SIMD2<Float>
    /// Magnitude multiplier for the per-layer shift, carried on the frame so
    /// every consumer (image layers, particles, text) uses one value. Override
    /// per machine: `defaults write Taijia.LiveWallpaper WPEParallaxGain <n>`;
    /// read at load, so reload the wallpaper after changing it.
    var gain: Double = WPECameraParallaxFrame.defaultGain

    /// The old 0.1 (±0.05 clamp) baked into the UV-shift path was never actually
    /// exercised — object `parallaxDepth` parsed to 0 until per-axis vector
    /// parsing landed — and was far weaker than WPE. 0.5 better matches WPE.
    static let defaultGain: Double = 0.5
    /// Safety ceiling so an extreme depth can't fling a layer off-screen — a
    /// fraction of the scene per axis. Generous enough not to clip real scenes.
    static let maxShiftFraction: Float = 0.2
    /// Upper bound for a `WPEParallaxGain` override (per-shift clamp is
    /// `maxShiftFraction` anyway).
    static let maxGain: Double = 20

    /// `nil` (key absent) or non-finite falls back to `defaultGain`; `0` is
    /// honored (parallax off); negatives clamp to 0; magnitude capped at `maxGain`.
    static func clampedGain(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite else { return defaultGain }
        return min(max(raw, 0), maxGain)
    }

    static let neutral = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0, 0))

    /// Each axis is scaled by its own depth so WPE's per-axis limiting works
    /// ("1 0" → horizontal only, "0 1" → vertical only). X is negated and Y kept
    /// so the layer moves with the cursor in the renderer's top-left scene space.
    func pixelOffset(depth: SIMD2<Double>, sceneSize: CGSize) -> SIMD2<Float> {
        let dx = Float(depth.x)
        let dy = Float(depth.y)
        let width = Float(sceneSize.width)
        let height = Float(sceneSize.height)
        guard dx.isFinite, dy.isFinite, width.isFinite, height.isFinite,
              dx != 0 || dy != 0, smoothed != SIMD2<Float>(0, 0) else {
            return SIMD2<Float>(0, 0)
        }
        let g = Float(gain)
        let m = Self.maxShiftFraction
        let ux = min(max(smoothed.x * dx * g, -m), m)
        let uy = min(max(smoothed.y * dy * g, -m), m)
        return SIMD2<Float>(-ux * max(width, 1), uy * max(height, 1))
    }
}

/// Frame-rate-independent exponential smoother for camera parallax. Holds the
/// smoothed cursor offset across frames. Neutral when the scene disables
/// parallax or zeroes amount / mouse-influence.
struct WPECameraParallaxSmoother: Equatable, Sendable {
    private(set) var smoothed = SIMD2<Float>(0, 0)
    private var lastTime: Double?

    mutating func reset() {
        smoothed = SIMD2<Float>(0, 0)
        lastTime = nil
    }

    /// `time` is monotonic scene-elapsed seconds. WPE defaults (amount 0.5,
    /// mouseInfluence 0.5) → `effectiveGlobal == 1`, preserving the historical
    /// per-layer depth magnitude.
    mutating func frame(
        settings: WPESceneCameraParallaxSettings,
        pointerPosition: SIMD2<Double>,
        time: Double,
        gain: Double = WPECameraParallaxFrame.defaultGain
    ) -> WPECameraParallaxFrame {
        let amount = max(settings.amount, 0)
        let influence = max(settings.mouseInfluence, 0)
        guard settings.enabled, amount > 0, influence > 0 else {
            smoothed = SIMD2<Float>(0, 0)
            lastTime = time
            return WPECameraParallaxFrame(smoothed: SIMD2<Float>(0, 0), gain: gain)
        }
        let effectiveGlobal = Float((amount / 0.5) * (influence / 0.5))
        let pointer = pointerPosition.clampedToUnitSquare
        let target = SIMD2<Float>(
            Float(pointer.x - 0.5) * effectiveGlobal,
            Float(pointer.y - 0.5) * effectiveGlobal
        )
        let rawDt = lastTime.map { max(time - $0, 0) }
        lastTime = time
        // First frame or a long gap (resume from suspend/idle) snaps to the
        // cursor instead of slow catch-up. Otherwise `dt` is clamped to a 10 FPS
        // floor: one heavy frame can't over-step, yet low frame rates stay
        // frame-rate independent.
        guard let rawDt, rawDt <= 0.5 else {
            smoothed = target
            return WPECameraParallaxFrame(smoothed: smoothed, gain: gain)
        }
        let dt = min(rawDt, 1.0 / 10.0)
        let alpha: Float = settings.delay <= 0
            ? 1
            : Float(1 - exp(-dt / max(settings.delay, 1.0 / 240.0)))
        smoothed += (target - smoothed) * alpha
        return WPECameraParallaxFrame(smoothed: smoothed, gain: gain)
    }
}

/// Per-frame WPE runtime uniforms produced by `WPEMetalFrameClock`, merged into
/// prepared pass uniforms before the Metal executor runs. Built-in shaders
/// ignore entries they don't bind.
struct WPEMetalRuntimeUniforms: Equatable, Sendable {
    let time: Double
    let daytime: Double
    let brightness: Double
    let pointerPosition: SIMD2<Double>
    /// Previous frame's pointer position (WPE's official `g_PointerPositionLast`,
    /// for motion-aware pointer shaders). Defaults to the current position so a
    /// fresh frame reports zero motion. Tracked by the renderer across frames —
    /// works with cursor-follow alone, no click capture needed.
    var pointerPositionLast: SIMD2<Double>
    /// Click state from the interactive view, meaningful only while the scene's
    /// per-screen "Interactive" (click capture) toggle is on; neutral otherwise.
    var pointerClick: WPEPointerFrame = .neutral
    var cameraParallax: WPECameraParallaxFrame = .neutral
    /// Per-channel spectrum, 64 bins each, normalized 0…1, low frequency → high.
    /// Fed from the shared system-audio broker. Audio-reactive shaders consume
    /// 16/32/64-element slices per channel via the resolution combo. Mono
    /// sources duplicate into both channels.
    let audioSpectrumLeft: [Double]
    let audioSpectrumRight: [Double]

    static let zero = WPEMetalRuntimeUniforms(
        time: 0,
        daytime: 0,
        brightness: 1,
        pointerPosition: SIMD2<Double>(0.5, 0.5)
    )

    /// Duplicates one 64-bin spectrum into both channels. For the frame-clock
    /// default path and fixtures.
    init(
        time: Double,
        daytime: Double,
        brightness: Double,
        pointerPosition: SIMD2<Double>,
        audioSpectrum: [Double] = [Double](repeating: 0, count: 64)
    ) {
        let mono = Self.normalized(audioSpectrum)
        self.init(
            time: time,
            daytime: daytime,
            brightness: brightness,
            pointerPosition: pointerPosition,
            audioSpectrumLeft: mono,
            audioSpectrumRight: mono
        )
    }

    init(
        time: Double,
        daytime: Double,
        brightness: Double,
        pointerPosition: SIMD2<Double>,
        audioSpectrumLeft: [Double],
        audioSpectrumRight: [Double]
    ) {
        self.time = time
        self.daytime = daytime
        self.brightness = brightness
        self.pointerPosition = pointerPosition
        // Default "no motion" — the renderer overwrites this with the actual
        // previous-frame pointer each frame.
        self.pointerPositionLast = pointerPosition
        self.audioSpectrumLeft = Self.normalized(audioSpectrumLeft)
        self.audioSpectrumRight = Self.normalized(audioSpectrumRight)
    }

    /// Clamps a spectrum to exactly 64 bins (truncate or zero-pad).
    private static func normalized(_ bins: [Double]) -> [Double] {
        if bins.count >= 64 { return Array(bins.prefix(64)) }
        return bins + [Double](repeating: 0, count: 64 - bins.count)
    }

    var uniformValues: [String: WPESceneShaderConstantValue] {
        let s64L = audioSpectrumLeft
        let s64R = audioSpectrumRight
        let s32L = Self.halve(s64L)
        let s32R = Self.halve(s64R)
        let s16L = Self.halve(s32L)
        let s16R = Self.halve(s32R)
        return [
            "g_Time": .number(time),
            "g_Daytime": .number(daytime),
            "g_Brightness": .number(brightness),
            "g_PointerPosition": .vector([pointerPosition.x, pointerPosition.y]),
            // Official WPE motion uniform + our internal click aliases (non-
            // official; documented in WPEInteractiveMTKView). Shaders that don't
            // declare these ignore them, so they're zero-cost.
            "g_PointerPositionLast": .vector([pointerPositionLast.x, pointerPositionLast.y]),
            "g_PointerClickPosition": .vector([pointerClick.clickPosition.x, pointerClick.clickPosition.y]),
            "g_PointerDown": .number(pointerClick.isDown ? 1 : 0),
            "g_PointerRightDown": .number(pointerClick.isRightDown ? 1 : 0),
            "g_AudioSpectrum16Left": .vector(s16L),
            "g_AudioSpectrum16Right": .vector(s16R),
            "g_AudioSpectrum32Left": .vector(s32L),
            "g_AudioSpectrum32Right": .vector(s32R),
            "g_AudioSpectrum64Left": .vector(s64L),
            "g_AudioSpectrum64Right": .vector(s64R),
            // WPE 2.8 neutral frame defaults. Shaders ignore entries they do not
            // declare, so these are zero-cost for non-2.8 passes and only matter
            // when a 2.8 shader binds them. `g_RenderVar0…3` default to zero,
            // which disables every optional font effect (outline/blur/shadow).
            "g_RenderVar0": .vector([0, 0, 0, 0]),
            "g_RenderVar1": .vector([0, 0, 0, 0]),
            "g_RenderVar2": .vector([0, 0, 0, 0]),
            "g_RenderVar3": .vector([0, 0, 0, 0]),
            // SDR pass-through identity for combine_video_hdr.frag, whose math is
            // `maxHDR = g_HDRParams.y * 2; rgb = saturate(rgb / maxHDR) * maxHDR`.
            // `.y = 0.5` ⇒ maxHDR = 1.0 ⇒ exact pass-through for [0,1] input
            // (`.y = 0` would divide by zero → NaN/black). `.x` is unused here.
            "g_HDRParams": .vector([1, 0.5])
        ]
    }

    /// Averages adjacent bins to halve resolution (64→32→16).
    private static func halve(_ bins: [Double]) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(bins.count / 2)
        var index = 0
        while index + 1 < bins.count {
            result.append((bins[index] + bins[index + 1]) * 0.5)
            index += 2
        }
        return result
    }
}

/// Deterministic clock for Metal frame uniforms. The closure-based
/// `currentMediaTime` and `currentDate` make the type trivial to drive from
/// fixtures while the default initializer falls back to `CACurrentMediaTime`
/// and `Date()` for production.
struct WPEMetalFrameClock: Sendable {
    let loadTime: CFTimeInterval

    private let currentMediaTime: @Sendable () -> CFTimeInterval
    private let currentDate: @Sendable () -> Date
    private let calendar: Calendar

    init(
        loadTime: CFTimeInterval = CACurrentMediaTime(),
        currentMediaTime: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() },
        currentDate: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.loadTime = loadTime
        self.currentMediaTime = currentMediaTime
        self.currentDate = currentDate
        self.calendar = calendar
    }

    func runtimeUniforms(
        profile: WallpaperPerformanceProfile,
        pointerPosition: SIMD2<Double>
    ) -> WPEMetalRuntimeUniforms {
        let elapsed = max(currentMediaTime() - loadTime, 0)
        let date = currentDate()
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
        let daytime = min(max(seconds / 86_400, 0), 1)

        return WPEMetalRuntimeUniforms(
            time: elapsed,
            daytime: daytime,
            brightness: profile.metalBrightnessUniformValue,
            pointerPosition: pointerPosition.clampedToUnitSquare
        )
    }
}

/// Pointer position sampler. `live` reads `NSEvent.mouseLocation` and maps it
/// to the renderer view's UV space; `fixed` is for fixtures that need a
/// known pointer position regardless of the cursor.
@MainActor
struct WPEMetalPointerSampler: Sendable {
    let sample: @MainActor @Sendable (NSView) -> SIMD2<Double>

    static let live = WPEMetalPointerSampler { view in
        normalizedSceneUV(mouseLocation: NSEvent.mouseLocation, in: view)
    }

    static func fixed(_ uv: SIMD2<Double>) -> WPEMetalPointerSampler {
        WPEMetalPointerSampler { _ in uv.clampedToUnitSquare }
    }

    static func normalizedSceneUV(mouseLocation: CGPoint, in view: NSView) -> SIMD2<Double> {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return SIMD2<Double>(0.5, 0.5)
        }

        let localPoint: CGPoint
        if let window = view.window {
            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            localPoint = view.convert(windowPoint, from: nil)
        } else {
            localPoint = view.convert(mouseLocation, from: nil)
        }

        let x = Double(localPoint.x / view.bounds.width)
        let y = 1.0 - Double(localPoint.y / view.bounds.height)
        return SIMD2<Double>(x, y).clampedToUnitSquare
    }
}

/// Camera/projection uniforms produced from `general.orthogonalprojection` +
/// the scene camera. Mirrors the WPE convention of a top-left origin so UV
/// math stays consistent across Metal scene passes.
struct WPEMetalCameraUniforms: Equatable, Sendable {
    let renderSize: CGSize
    let viewProjectionMatrix: [Double]
    let usesPerspectiveProjection: Bool
    let sceneCamera: WPESceneCamera

    static let identity = WPEMetalCameraUniforms(
        renderSize: CGSize(width: 1, height: 1),
        viewProjectionMatrix: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ],
        usesPerspectiveProjection: false,
        sceneCamera: .defaultCamera
    )

    init(
        orthogonalProjection: WPESceneOrthogonalProjection,
        sceneCamera: WPESceneCamera,
        usesPerspectiveProjection: Bool = false
    ) {
        let width = max(orthogonalProjection.width, 1)
        let height = max(orthogonalProjection.height, 1)
        renderSize = CGSize(width: width, height: height)
        self.usesPerspectiveProjection = usesPerspectiveProjection
        self.sceneCamera = sceneCamera
        viewProjectionMatrix = usesPerspectiveProjection
            ? Self.perspectiveViewProjectionMatrix(
                sceneCamera: sceneCamera,
                aspect: Double(width) / Double(height)
            )
            : Self.topLeftOrthographicMatrix(
                width: Double(width),
                height: Double(height),
                nearZ: sceneCamera.nearZ,
                farZ: sceneCamera.farZ
            )
    }

    private init(
        renderSize: CGSize,
        viewProjectionMatrix: [Double],
        usesPerspectiveProjection: Bool,
        sceneCamera: WPESceneCamera
    ) {
        self.renderSize = renderSize
        self.viewProjectionMatrix = viewProjectionMatrix
        self.usesPerspectiveProjection = usesPerspectiveProjection
        self.sceneCamera = sceneCamera
    }

    var uniformValues: [String: WPESceneShaderConstantValue] {
        [
            "g_ViewProjectionMatrix": .vector(viewProjectionMatrix)
        ]
    }

    private static func topLeftOrthographicMatrix(
        width: Double,
        height: Double,
        nearZ: Double,
        farZ: Double
    ) -> [Double] {
        let left = 0.0
        let right = width
        let top = 0.0
        let bottom = height
        let near = nearZ
        let far = farZ == nearZ ? nearZ + 1 : farZ

        return [
            2.0 / (right - left), 0, 0, 0,
            0, 2.0 / (top - bottom), 0, 0,
            0, 0, 1.0 / (near - far), 0,
            (left + right) / (left - right),
            (top + bottom) / (bottom - top),
            near / (near - far),
            1
        ]
    }

    private static func perspectiveViewProjectionMatrix(
        sceneCamera: WPESceneCamera,
        aspect: Double
    ) -> [Double] {
        let eye = sceneCamera.eye
        let center = sceneCamera.center
        let upSeed = sceneCamera.up
        let forward = normalized(center - eye, fallback: SIMD3<Double>(0, 0, -1))
        let right = normalized(simd_cross(forward, upSeed), fallback: SIMD3<Double>(1, 0, 0))
        let up = normalized(simd_cross(right, forward), fallback: SIMD3<Double>(0, 1, 0))

        let fovRadians = max(min(sceneCamera.fov, 179), 1) * .pi / 180
        let f = 1.0 / tan(fovRadians * 0.5)
        let zNear = max(sceneCamera.nearZ, 0.0001)
        let zFar = max(sceneCamera.farZ, zNear + 0.0001)

        let projection = [
            f / max(aspect, 0.0001), 0, 0, 0,
            0, f, 0, 0,
            0, 0, zFar / (zNear - zFar), -1,
            0, 0, (zNear * zFar) / (zNear - zFar), 0
        ]
        let view = [
            right.x, up.x, -forward.x, 0,
            right.y, up.y, -forward.y, 0,
            right.z, up.z, -forward.z, 0,
            -simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1
        ]
        return multiply4x4(projection, view)
    }

    private static func normalized(
        _ value: SIMD3<Double>,
        fallback: SIMD3<Double>
    ) -> SIMD3<Double> {
        let length = simd_length(value)
        guard length.isFinite, length > 0.000001 else { return fallback }
        return value / length
    }

    private static func multiply4x4(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        guard lhs.count == 16, rhs.count == 16 else { return lhs }
        var out = [Double](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                var sum = 0.0
                for k in 0..<4 {
                    sum += lhs[k * 4 + row] * rhs[column * 4 + k]
                }
                out[column * 4 + row] = sum
            }
        }
        return out
    }
}

extension WallpaperPerformanceProfile {
    /// `g_Brightness` fed to image shaders, which compute
    /// `rgb = sampled.rgb * color.rgb * g_Brightness`. This MUST stay 1 in
    /// both states: returning 0 for `.suspended` rendered every `genericimage*`
    /// layer as a pure-black silhouette (alpha is a separate term, so the shape
    /// survived) whenever a frame was produced while suspended — most visibly
    /// the first frame during load and any not-fully-occluded paused wallpaper.
    /// Suspension saves power via `mtkView.isPaused`, not by dimming content to
    /// black; a paused wallpaper should show its scene frozen, not blanked.
    var metalBrightnessUniformValue: Double {
        switch self {
        case .quality, .suspended:
            return 1
        }
    }
}

private extension SIMD2 where Scalar == Double {
    var clampedToUnitSquare: SIMD2<Double> {
        SIMD2<Double>(
            Swift.min(Swift.max(x, 0), 1),
            Swift.min(Swift.max(y, 0), 1)
        )
    }
}
#endif
