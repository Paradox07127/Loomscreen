import AppKit
import Foundation
import QuartzCore

/// Per-frame WPE runtime uniforms produced by `WPEMetalFrameClock` and merged
/// into prepared pass uniforms before the Metal executor runs. Built-in
/// shaders ignore the entries they do not bind, so this layer can ship before
/// the Phase 2D custom-shader translator consumes them.
struct WPEMetalRuntimeUniforms: Equatable, Sendable {
    let time: Double
    let daytime: Double
    let brightness: Double
    let pointerPosition: SIMD2<Double>
    /// Mono spectrum, length 64. Audio-reactive shaders consume 16/32/64
    /// element slices via the resolution combo. Default zero — when the
    /// scene's audio runtime feeds real FFT bins, replace it. Each bin
    /// is a normalized 0…1 magnitude, ordered low frequency → high.
    let audioSpectrum: [Double]

    static let zero = WPEMetalRuntimeUniforms(
        time: 0,
        daytime: 0,
        brightness: 1,
        pointerPosition: SIMD2<Double>(0.5, 0.5),
        audioSpectrum: [Double](repeating: 0, count: 64)
    )

    init(
        time: Double,
        daytime: Double,
        brightness: Double,
        pointerPosition: SIMD2<Double>,
        audioSpectrum: [Double] = [Double](repeating: 0, count: 64)
    ) {
        self.time = time
        self.daytime = daytime
        self.brightness = brightness
        self.pointerPosition = pointerPosition
        // Pad/truncate so consumers can always pull the slice they need.
        if audioSpectrum.count >= 64 {
            self.audioSpectrum = Array(audioSpectrum.prefix(64))
        } else {
            var padded = audioSpectrum
            padded.append(contentsOf: [Double](repeating: 0, count: 64 - audioSpectrum.count))
            self.audioSpectrum = padded
        }
    }

    var uniformValues: [String: WPESceneShaderConstantValue] {
        // Build the spectrum slices the audio-reactive shader family
        // consumes. Same data, three resolutions — the shader's combo
        // selects which one it samples; we publish all so the dispatcher
        // hits whichever the translated MSL aliased.
        let s64 = audioSpectrum
        let s32 = stride(from: 0, to: 64, by: 2).map { (i: Int) -> Double in
            (s64[i] + s64[i + 1]) * 0.5
        }
        let s16 = stride(from: 0, to: 32, by: 2).map { (i: Int) -> Double in
            (s32[i] + s32[i + 1]) * 0.5
        }
        return [
            "g_Time": .number(time),
            "g_Daytime": .number(daytime),
            "g_Brightness": .number(brightness),
            "g_PointerPosition": .vector([pointerPosition.x, pointerPosition.y]),
            // Audio runtime: same array fills both stereo channels until
            // a per-channel runtime ships. Audio-reactive scenes will
            // animate as silence when the source isn't producing audio.
            "g_AudioSpectrum16Left": .vector(s16),
            "g_AudioSpectrum16Right": .vector(s16),
            "g_AudioSpectrum32Left": .vector(s32),
            "g_AudioSpectrum32Right": .vector(s32),
            "g_AudioSpectrum64Left": .vector(s64),
            "g_AudioSpectrum64Right": .vector(s64)
        ]
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
/// math stays consistent with the existing CGImage/SpriteKit paths.
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
    var metalBrightnessUniformValue: Double {
        switch self {
        case .quality:
            return 1
        case .suspended:
            return 0
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
