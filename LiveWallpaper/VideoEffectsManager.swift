@preconcurrency import AVFoundation
import CoreImage
import Foundation

/// Immutable snapshot of filter parameters, safe to share across threads.
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

/// Builds and manages a CIFilter pipeline applied to video playback.
/// Filters and CIContext are cached to avoid per-frame allocation.
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
        let applier: @Sendable (AVCIImageFilteringParameters) async throws -> AVCIImageFilteringResult = { parameters in
            let sourceExtent = parameters.sourceImage.extent
            let filtered = applyFilters(to: parameters.sourceImage.clampedToExtent(), params: params)
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
        let mutable = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { request in
                let sourceExtent = request.sourceImage.extent
                let filtered = applyFilters(to: request.sourceImage.clampedToExtent(), params: params)
                request.finish(with: filtered.cropped(to: sourceExtent), context: nil)
            }
        )
        mutable.frameDuration = frameDuration
        return mutable
    }

    // MARK: - Filter pipeline

    nonisolated private static func applyFilters(
        to source: CIImage,
        params: FilterParameters
    ) -> CIImage {
        var image = source

        if params.blurRadius > 0, let f = CIFilter(name: "CIGaussianBlur") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(params.blurRadius, forKey: kCIInputRadiusKey)
            image = f.outputImage ?? image
        }

        if params.saturation != 1.0 || params.brightness != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(params.saturation, forKey: kCIInputSaturationKey)
            f.setValue(params.brightness, forKey: kCIInputBrightnessKey)
            image = f.outputImage ?? image
        }

        let warmth = params.autoTimeTint ? warmthForCurrentHour() : params.warmth
        if warmth != 6500, let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: CGFloat(warmth), y: 0), forKey: "inputTargetNeutral")
            image = f.outputImage ?? image
        }

        if params.vignetteIntensity > 0, let f = CIFilter(name: "CIVignette") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(params.vignetteIntensity, forKey: kCIInputIntensityKey)
            f.setValue(max(params.vignetteIntensity * 2, 1.0), forKey: kCIInputRadiusKey)
            image = f.outputImage ?? image
        }

        return image
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
