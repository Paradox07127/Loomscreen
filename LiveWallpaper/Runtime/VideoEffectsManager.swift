@preconcurrency import AVFoundation
import CoreImage
import Foundation

struct FilterParameters: Sendable {
    let blurRadius: Double
    let saturation: Double
    let brightness: Double
    let warmth: Double
    let vignetteIntensity: Double
    let autoTimeTint: Bool

    init(from config: VideoEffectConfig) {
        self.blurRadius = config.blurRadius
        self.saturation = config.saturation
        self.brightness = config.brightness
        self.warmth = config.warmth
        self.vignetteIntensity = config.vignetteIntensity
        self.autoTimeTint = config.autoTimeTint
    }
}

@MainActor
final class VideoEffectsManager {

    // MARK: - Properties

    private(set) var parameters: FilterParameters

    // MARK: - Initialization

    init(config: VideoEffectConfig = .default) {
        self.parameters = FilterParameters(from: config)
    }

    // MARK: - Configuration

    func updateConfig(_ config: VideoEffectConfig) {
        parameters = FilterParameters(from: config)
    }

    // MARK: - Composition Building

    func buildComposition(
        for asset: AVAsset,
        config: VideoEffectConfig,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        updateConfig(config)
        let params = self.parameters

        if #available(macOS 26.0, *) {
            return try await Self.buildUsingApplier(
                asset: asset,
                params: params,
                frameDuration: frameDuration
            )
        } else {
            return try await Self.buildUsingHandler(
                asset: asset,
                params: params,
                frameDuration: frameDuration
            )
        }
    }

    // MARK: - macOS 26 path (async applier + Configuration copy)

    @available(macOS 26.0, *)
    private nonisolated static func buildUsingApplier(
        asset: AVAsset,
        params: FilterParameters,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        let chain = VideoFilterChain(params: params)
        let applier: @Sendable (AVCIImageFilteringParameters) async throws -> AVCIImageFilteringResult = { parameters in
            let sourceExtent = parameters.sourceImage.extent
            let filtered = chain.apply(to: parameters.sourceImage.clampedToExtent())
            return AVCIImageFilteringResult(resultImage: filtered.cropped(to: sourceExtent))
        }

        let composition = try await AVVideoComposition(applyingFiltersTo: asset, applier: applier)

        return AVVideoComposition(
            configuration: AVVideoComposition.Configuration(
                animationTool: composition.animationTool,
                colorPrimaries: composition.colorPrimaries,
                colorTransferFunction: composition.colorTransferFunction,
                colorYCbCrMatrix: composition.colorYCbCrMatrix,
                customVideoCompositorClass: composition.customVideoCompositorClass,
                frameDuration: frameDuration,
                instructions: composition.instructions,
                outputBufferDescription: composition.outputBufferDescription,
                perFrameHDRDisplayMetadataPolicy: composition.perFrameHDRDisplayMetadataPolicy,
                renderScale: composition.renderScale,
                renderSize: composition.renderSize,
                sourceSampleDataTrackIDs: composition.sourceSampleDataTrackIDs,
                sourceTrackIDForFrameTiming: composition.sourceTrackIDForFrameTiming,
                spatialVideoConfigurations: composition.spatialVideoConfigurations
            )
        )
    }

    // MARK: - macOS 14/15 path (handler-based init + mutable copy)

    private nonisolated static func buildUsingHandler(
        asset: AVAsset,
        params: FilterParameters,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        let chain = VideoFilterChain(params: params)
        let mutable = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let sourceExtent = request.sourceImage.extent
                let filtered = chain.apply(to: request.sourceImage.clampedToExtent())
                request.finish(with: filtered.cropped(to: sourceExtent), context: nil)
            }
        )
        mutable.frameDuration = frameDuration
        return mutable
    }

    // MARK: - Time-of-Day Warmth

    nonisolated static func warmthForCurrentHour() -> Double {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<9:   return 5500
        case 9..<17:  return 6500
        case 17..<20: return 4500
        case 20..<23: return 3500
        default:      return 3000
        }
    }
}

/// Per-composition CIFilter chain, built once and reused across frames instead
/// of reconstructing filters via `CIFilter(name:)` on every decoded frame.
/// AVFoundation does not document serial delivery for the per-frame filtering
/// callbacks and `CIFilter` is not thread-safe, so input mutation is guarded by
/// a lock; `outputImage` snapshots inputs into the returned `CIImage`, so the
/// lock never spans actual rendering.
private final class VideoFilterChain: @unchecked Sendable {
    private let params: FilterParameters
    private let lock = NSLock()
    private let blur: CIFilter?
    private let colorControls: CIFilter?
    private let temperature: CIFilter?
    private let vignette: CIFilter?
    private var appliedWarmth: Double?

    init(params: FilterParameters) {
        self.params = params

        if params.blurRadius > 0, let f = CIFilter(name: "CIGaussianBlur") {
            f.setValue(params.blurRadius, forKey: kCIInputRadiusKey)
            blur = f
        } else {
            blur = nil
        }

        if params.saturation != 1.0 || params.brightness != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(params.saturation, forKey: kCIInputSaturationKey)
            f.setValue(params.brightness, forKey: kCIInputBrightnessKey)
            colorControls = f
        } else {
            colorControls = nil
        }

        // With autoTimeTint the effective warmth changes at hour boundaries, so
        // the filter must exist even when the current hour maps to neutral.
        if params.autoTimeTint || params.warmth != 6500, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            temperature = f
        } else {
            temperature = nil
        }

        if params.vignetteIntensity > 0, let f = CIFilter(name: "CIVignette") {
            f.setValue(params.vignetteIntensity, forKey: kCIInputIntensityKey)
            f.setValue(max(params.vignetteIntensity * 2, 1.0), forKey: kCIInputRadiusKey)
            vignette = f
        } else {
            vignette = nil
        }
    }

    func apply(to source: CIImage) -> CIImage {
        lock.lock()
        defer { lock.unlock() }

        var image = source

        if let f = blur {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        if let f = colorControls {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        if let f = temperature {
            let warmth = params.autoTimeTint ? VideoEffectsManager.warmthForCurrentHour() : params.warmth
            if warmth != 6500 {
                if warmth != appliedWarmth {
                    f.setValue(CIVector(x: CGFloat(warmth), y: 0), forKey: "inputTargetNeutral")
                    appliedWarmth = warmth
                }
                f.setValue(image, forKey: kCIInputImageKey)
                image = f.outputImage ?? image
            }
        }

        if let f = vignette {
            f.setValue(image, forKey: kCIInputImageKey)
            image = f.outputImage ?? image
        }

        return image
    }
}
