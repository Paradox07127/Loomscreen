#if !LITE_BUILD
import AppKit
import Foundation
import QuartzCore

/// Per-frame WPE runtime uniforms produced by `WPEMetalFrameClock` and merged
/// into prepared pass uniforms before the Metal executor runs. Built-in
/// shaders ignore the entries they do not bind, so this layer can ship before
/// the Phase 2D custom-shader translator consumes them.
/// Per-frame, smoothed camera-parallax state. `smoothed` is the cursor offset
/// from screen center (−0.5…0.5 per axis) after exponential smoothing and the
/// scene's amount/mouse-influence calibration. `pixelOffset` turns it into a
/// per-layer scene-pixel translation scaled by that layer's `parallaxDepth`.
struct WPECameraParallaxFrame: Equatable, Sendable {
    var smoothed: SIMD2<Float>

    static let neutral = WPECameraParallaxFrame(smoothed: SIMD2<Float>(0, 0))

    /// Scene-pixel translation for a layer at per-axis `depth`. Mirrors the
    /// historical UV-parallax magnitude (`× depth × 0.1`, clamped ±0.05) but
    /// expressed as a geometry shift, with each axis scaled by its own depth so
    /// WPE's per-axis limiting works ("1 0" → horizontal only, "0 1" → vertical
    /// only). X is negated and Y kept so the layer moves with the cursor in the
    /// renderer's top-left scene space.
    func pixelOffset(depth: SIMD2<Double>, sceneSize: CGSize) -> SIMD2<Float> {
        let dx = Float(depth.x)
        let dy = Float(depth.y)
        let width = Float(sceneSize.width)
        let height = Float(sceneSize.height)
        guard dx.isFinite, dy.isFinite, width.isFinite, height.isFinite,
              dx != 0 || dy != 0, smoothed != SIMD2<Float>(0, 0) else {
            return SIMD2<Float>(0, 0)
        }
        let ux = min(max(smoothed.x * dx * 0.1, -0.05), 0.05)
        let uy = min(max(smoothed.y * dy * 0.1, -0.05), 0.05)
        return SIMD2<Float>(-ux * max(width, 1), uy * max(height, 1))
    }
}

/// Frame-rate-independent exponential smoother for camera parallax. Holds the
/// smoothed cursor offset across frames; `frame(...)` advances it toward the
/// (calibrated) cursor target each frame. Neutral when the scene disables
/// parallax or zeroes amount / mouse-influence. Kept as a value type so it can
/// be unit-tested independently of the renderer.
struct WPECameraParallaxSmoother: Equatable, Sendable {
    private(set) var smoothed = SIMD2<Float>(0, 0)
    private var lastTime: Double?

    mutating func reset() {
        smoothed = SIMD2<Float>(0, 0)
        lastTime = nil
    }

    /// `time` is monotonic scene-elapsed seconds. WPE defaults (amount 0.5,
    /// mouseInfluence 0.5) → `effectiveGlobal == 1`, preserving the historical
    /// per-layer depth magnitude. `dt` is clamped so a long suspend doesn't
    /// snap on resume; the first frame snaps directly to the cursor.
    mutating func frame(
        settings: WPESceneCameraParallaxSettings,
        pointerPosition: SIMD2<Double>,
        time: Double
    ) -> WPECameraParallaxFrame {
        let amount = max(settings.amount, 0)
        let influence = max(settings.mouseInfluence, 0)
        guard settings.enabled, amount > 0, influence > 0 else {
            smoothed = SIMD2<Float>(0, 0)
            lastTime = time
            return .neutral
        }
        let effectiveGlobal = Float((amount / 0.5) * (influence / 0.5))
        let pointer = pointerPosition.clampedToUnitSquare
        let target = SIMD2<Float>(
            Float(pointer.x - 0.5) * effectiveGlobal,
            Float(pointer.y - 0.5) * effectiveGlobal
        )
        let rawDt = lastTime.map { max(time - $0, 0) }
        lastTime = time
        // First frame, or a long gap (resume from suspend / idle), snaps to the
        // cursor instead of a slow catch-up. Otherwise clamp `dt` to a 10 FPS
        // floor so a single heavy frame can't over-step yet low frame rates stay
        // frame-rate independent.
        guard let rawDt, rawDt <= 0.5 else {
            smoothed = target
            return WPECameraParallaxFrame(smoothed: smoothed)
        }
        let dt = min(rawDt, 1.0 / 10.0)
        let alpha: Float = settings.delay <= 0
            ? 1
            : Float(1 - exp(-dt / max(settings.delay, 1.0 / 240.0)))
        smoothed += (target - smoothed) * alpha
        return WPECameraParallaxFrame(smoothed: smoothed)
    }
}

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
    /// Scene-level camera parallax for this frame (neutral when disabled).
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

    /// Mono initializer — duplicates one 64-bin spectrum into both channels.
    /// Kept for the frame-clock default path and fixtures.
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

    /// Stereo initializer — independent left/right 64-bin spectra.
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
        stride(from: 0, to: bins.count, by: 2).map { i in
            (bins[i] + bins[i + 1]) * 0.5
        }
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

    static let identity = WPEMetalCameraUniforms(
        renderSize: CGSize(width: 1, height: 1),
        viewProjectionMatrix: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        ]
    )

    init(
        orthogonalProjection: WPESceneOrthogonalProjection,
        sceneCamera: WPESceneCamera
    ) {
        let width = max(orthogonalProjection.width, 1)
        let height = max(orthogonalProjection.height, 1)
        renderSize = CGSize(width: width, height: height)
        viewProjectionMatrix = Self.topLeftOrthographicMatrix(
            width: Double(width),
            height: Double(height),
            nearZ: sceneCamera.nearZ,
            farZ: sceneCamera.farZ
        )
    }

    private init(renderSize: CGSize, viewProjectionMatrix: [Double]) {
        self.renderSize = renderSize
        self.viewProjectionMatrix = viewProjectionMatrix
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
