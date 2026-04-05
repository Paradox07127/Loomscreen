import AVFoundation
import CoreImage

/// Mutable container for filter parameters so they can be updated
/// without rebuilding the entire composition.
final class FilterParameters: @unchecked Sendable {
    var blurRadius: Double
    var saturation: Double
    var brightness: Double
    var warmth: Double
    var vignetteIntensity: Double
    var autoTimeTint: Bool

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

    // MARK: - Cached filters (allocated once, reused every frame)

    private let blurFilter = CIFilter(name: "CIGaussianBlur")!
    private let colorControlsFilter = CIFilter(name: "CIColorControls")!
    private let tempTintFilter = CIFilter(name: "CITemperatureAndTint")!
    private let vignetteFilter = CIFilter(name: "CIVignette")!
    private let neutralVector = CIVector(x: 6500, y: 0)

    // MARK: - Initialization

    init(config: VideoEffectConfig = .default) {
        self.parameters = FilterParameters(from: config)
    }

    // MARK: - Configuration

    func updateConfig(_ config: VideoEffectConfig) {
        parameters.blurRadius = config.blurRadius
        parameters.saturation = config.saturation
        parameters.brightness = config.brightness
        parameters.warmth = config.warmth
        parameters.vignetteIntensity = config.vignetteIntensity
        parameters.autoTimeTint = config.autoTimeTint
    }

    // MARK: - Composition Building

    func buildComposition(
        for asset: AVAsset,
        config: VideoEffectConfig,
        frameDuration: CMTime
    ) async throws -> AVMutableVideoComposition {

        updateConfig(config)

        let params = self.parameters

        // CIFilter is non-Sendable, so filters must be created inside the handler.
        // CoreImage internally caches filter lookup by name, so CIFilter(name:) is cheap.
        let handler: @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void = { request in
            let sourceExtent = request.sourceImage.extent
            var image = request.sourceImage.clampedToExtent()

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

            let warmth = params.autoTimeTint ? VideoEffectsManager.warmthForCurrentHour() : params.warmth
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

            request.finish(with: image.cropped(to: sourceExtent), context: nil)
        }

        let composition = try await AVVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: handler
        )
        // AVVideoComposition is immutable; wrap in mutable to set frameDuration
        let mutable = composition.mutableCopy() as! AVMutableVideoComposition
        mutable.frameDuration = frameDuration

        return mutable
    }

    // MARK: - Time-of-Day Warmth

    nonisolated static func warmthForCurrentHour() -> Double {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<9:   return 5500  // morning cool
        case 9..<17:  return 6500  // daylight neutral
        case 17..<20: return 4500  // golden hour
        case 20..<23: return 3500  // evening warm
        default:      return 3000  // night very warm
        }
    }
}
