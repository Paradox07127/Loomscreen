import AVFoundation
import CoreImage

/// Mutable container for filter parameters so they can be updated (e.g. animated)
/// without rebuilding the entire composition.
final class FilterParameters {
    var blurRadius: Double
    var saturation: Double
    var brightness: Double
    var warmth: Double          // color temperature in Kelvin
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

/// Builds and manages a CIFilter pipeline that is applied to video playback
/// through an `AVMutableVideoComposition`.
final class VideoEffectsManager {

    // MARK: - Properties

    /// Current live parameters. Mutating this object affects the next rendered frame
    /// because the composition handler captures it by reference.
    private(set) var parameters: FilterParameters

    // MARK: - Initialization

    init(config: VideoEffectConfig = .default) {
        self.parameters = FilterParameters(from: config)
    }

    // MARK: - Configuration

    /// Replace all parameters from a new config snapshot.
    func updateConfig(_ config: VideoEffectConfig) {
        parameters.blurRadius = config.blurRadius
        parameters.saturation = config.saturation
        parameters.brightness = config.brightness
        parameters.warmth = config.warmth
        parameters.vignetteIntensity = config.vignetteIntensity
        parameters.autoTimeTint = config.autoTimeTint
    }

    // MARK: - Composition Building

    /// Creates an `AVMutableVideoComposition` with a CIFilter-based handler
    /// that reads from `self.parameters` on every frame.
    ///
    /// - Parameters:
    ///   - asset: The video asset to compose.
    ///   - config: Initial effect configuration.
    ///   - frameDuration: Desired frame duration (e.g. 1/30 for 30 FPS).
    /// - Returns: A configured `AVMutableVideoComposition`.
    func buildComposition(
        for asset: AVAsset,
        config: VideoEffectConfig,
        frameDuration: CMTime
    ) async throws -> AVMutableVideoComposition {

        updateConfig(config)

        // Capture parameters reference — the handler reads latest values each frame
        let params = self.parameters

        let handler: (AVAsynchronousCIImageFilteringRequest) -> Void = { request in
            let sourceExtent = request.sourceImage.extent
            var image = request.sourceImage.clampedToExtent()

            // 1. Gaussian Blur
            if params.blurRadius > 0 {
                let blur = CIFilter(name: "CIGaussianBlur")!
                blur.setValue(image, forKey: kCIInputImageKey)
                blur.setValue(params.blurRadius, forKey: kCIInputRadiusKey)
                image = blur.outputImage ?? image
            }

            // 2. Color Controls (saturation + brightness)
            if params.saturation != 1.0 || params.brightness != 0 {
                let controls = CIFilter(name: "CIColorControls")!
                controls.setValue(image, forKey: kCIInputImageKey)
                controls.setValue(params.saturation, forKey: kCIInputSaturationKey)
                controls.setValue(params.brightness, forKey: kCIInputBrightnessKey)
                image = controls.outputImage ?? image
            }

            // 3. Color Temperature (warmth)
            let effectiveWarmth = params.autoTimeTint
                ? VideoEffectsManager.warmthForCurrentHour()
                : params.warmth

            if effectiveWarmth != 6500 {
                let temp = CIFilter(name: "CITemperatureAndTint")!
                temp.setValue(image, forKey: kCIInputImageKey)
                temp.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                temp.setValue(CIVector(x: CGFloat(effectiveWarmth), y: 0), forKey: "inputTargetNeutral")
                image = temp.outputImage ?? image
            }

            // 4. Vignette
            if params.vignetteIntensity > 0 {
                let vignette = CIFilter(name: "CIVignette")!
                vignette.setValue(image, forKey: kCIInputImageKey)
                vignette.setValue(params.vignetteIntensity, forKey: kCIInputIntensityKey)
                vignette.setValue(max(params.vignetteIntensity * 2, 1.0), forKey: kCIInputRadiusKey)
                image = vignette.outputImage ?? image
            }

            // Crop back to source extent (removes infinite-extent blur artifacts)
            request.finish(with: image.cropped(to: sourceExtent), context: nil)
        }

        // The convenience initializer auto-creates instructions from the asset
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: handler)
        composition.frameDuration = frameDuration

        Logger.info("Built effects composition (blur=\(Int(config.blurRadius)) sat=\(config.saturation) warm=\(Int(config.warmth))K vig=\(config.vignetteIntensity))", category: .videoPlayer)

        return composition
    }

    // MARK: - Time-of-Day Warmth

    /// Returns a color temperature in Kelvin based on the current hour of day.
    /// - Morning  (5-9):   5500 K  (slightly cool, crisp daylight)
    /// - Daytime  (10-16): 6500 K  (neutral)
    /// - Evening  (17-20): 4000 K  (warm golden hour)
    /// - Night    (21-4):  3000 K  (very warm, low blue light)
    static func warmthForCurrentHour() -> Double {
        let hour = Calendar.current.component(.hour, from: Date())

        switch hour {
        case 5...9:
            return 5500
        case 10...16:
            return 6500
        case 17...20:
            return 4000
        default:
            // 21-23 and 0-4
            return 3000
        }
    }
}
