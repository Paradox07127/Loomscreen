@preconcurrency import AVFoundation
import CoreImage

/// Immutable snapshot of filter parameters, safe to share across threads.
struct FilterParameters: Sendable {
    let blurRadius: Double
    let saturation: Double
    let brightness: Double
    let warmth: Double
    let vignetteIntensity: Double
    let autoTimeTint: Bool
    let glassRainEffect: Bool

    init(from config: VideoEffectConfig) {
        self.blurRadius = config.blurRadius
        self.saturation = config.saturation
        self.brightness = config.brightness
        self.warmth = config.warmth
        self.vignetteIntensity = config.vignetteIntensity
        self.autoTimeTint = config.autoTimeTint
        self.glassRainEffect = config.glassRainEffect
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
            
            if params.glassRainEffect {
                let rainFilter = RainGlassFilter()
                rainFilter.inputImage = image
                rainFilter.inputTime = NSNumber(value: request.compositionTime.seconds)
                rainFilter.inputResolution = CIVector(x: sourceExtent.width, y: sourceExtent.height)
                image = rainFilter.outputImage ?? image
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

        // Use the async factory method for CIFilter composition.
        // Then re-wrap via Configuration to update frameDuration safely
        // (AVMutableVideoComposition is deprecated in macOS 26).
        let base = try await AVVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: handler
        )

        // CIFilter compositions use internal AVCoreImageFilterVideoCompositionInstruction
        // objects that cannot be transferred to AVVideoComposition.Configuration (crashes
        // with -[... dictionaryRepresentation]: unrecognized selector). Use the deprecated
        // mutableCopy path until Apple provides a CIFilter-aware Configuration API.
        guard let mutable = base.mutableCopy() as? AVMutableVideoComposition else {
            return base
        }
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

// MARK: - Rain Glass Filter

/// Simulates rain drops hitting a glass surface and refracting the underlying video.
class RainGlassFilter: CIFilter, @unchecked Sendable {
    @objc dynamic var inputImage: CIImage?
    @objc dynamic var inputTime: NSNumber = 0.0
    @objc dynamic var inputResolution: CIVector = CIVector(x: 1920, y: 1080)

    // Generate a displacement map procedurally using a CIColorKernel,
    // then feed it into CIDisplacementDistortion to avoid coordinate space bounds crashes.
    // Based on the popular "Heartfelt" rain drop algorithm.
    static let displacementMapKernel: CIColorKernel? = {
        let source = """
        kernel vec4 rainDisplacementMap(float time, vec2 resolution) {
            vec2 uv = destCoord() / resolution;
            vec2 aspect = vec2(resolution.x / resolution.y, 1.0);
            float t = mod(time * 0.2, 7200.0); // Prevent overflow
            
            vec2 normal = vec2(0.0);
            
            // Loop over 2 layers for depth and parallax
            for(float i = 0.0; i < 2.0; i += 1.0) {
                float layerScale = 4.0 + i * 3.0; // Grid scale
                vec2 st = uv * aspect * layerScale;
                st.y += t * (1.0 + i * 0.5); // Fall speed
                
                vec2 id = floor(st);
                vec2 f = fract(st) - 0.5;
                
                // Noise hash per grid cell
                vec2 hashP = id * vec2(123.34, 345.45);
                hashP += dot(hashP, hashP + 34.345);
                float n = fract(hashP.x * hashP.y);
                
                float localTime = t + n * 6.28;
                
                // Main drop position (stick-slip physics simulation)
                float dropY = -sin(localTime + sin(localTime + sin(localTime) * 0.5)) * 0.45;
                vec2 dropCenter = vec2((n - 0.5) * 0.7, dropY);
                vec2 dropPos = f - dropCenter;
                
                float mainDrop = smoothstep(0.12, 0.02, length(dropPos));
                
                // Trail mask (leaves small drops behind the main drop)
                vec2 trailPos = f - vec2(dropCenter.x, 0.0);
                trailPos.y = (fract(trailPos.y * 6.0) - 0.5) * 0.15;
                float trailMask = smoothstep(-dropCenter.y, 0.45, f.y);
                float trailDrop = smoothstep(0.04, 0.01, length(trailPos)) * trailMask;
                
                // Static background drops (only show sometimes based on noise)
                vec2 staticPos = f - vec2((n - 0.5) * 0.5, (fract(n * 12.34) - 0.5) * 0.5);
                float staticDrops = smoothstep(-0.5, 1.0, n) * smoothstep(0.05, 0.01, length(staticPos));
                
                // Accumulate refraction normal
                normal += dropPos * mainDrop + trailPos * trailDrop + staticPos * staticDrops;
            }
            
            // Add slight global ripple distortion (simulates foggy or uneven glass)
            float ripple = sin(uv.y * 10.0 + time) * cos(uv.x * 8.0 + time) * 0.02;
            normal.x += ripple;
            
            // Encode normal into displacement map (0.5 is neutral)
            vec2 encodedNormal = clamp((normal * 0.5) + 0.5, 0.0, 1.0);
            return vec4(encodedNormal.x, encodedNormal.y, 0.0, 1.0);
        }
        """
        return CIColorKernel(source: source)
    }()

    override var outputImage: CIImage? {
        guard let inputImage = inputImage else { return nil }
        
        guard let kernel = Self.displacementMapKernel else {
            return inputImage
        }
        
        // Use the resolution vector to create a finite extent.
        // If we use inputImage.extent directly when it's clamped (infinite), 
        // it will crash the AVVideoComposition pipeline with 'Operation Stopped'.
        let finiteExtent = CGRect(x: 0, y: 0, width: CGFloat(inputResolution.x), height: CGFloat(inputResolution.y))
        
        // Generate the displacement map over the finite extent
        guard let displacementMap = kernel.apply(
            extent: finiteExtent,
            arguments: [inputTime, inputResolution]
        ) else { return inputImage }
        
        // Apply CIDisplacementDistortion
        // The scale determines how strongly the displacement map distorts the image.
        // We set it relative to the height of the video to keep it resolution-independent.
        let distortionFilter = CIFilter(name: "CIDisplacementDistortion")!
        distortionFilter.setValue(inputImage, forKey: kCIInputImageKey)
        distortionFilter.setValue(displacementMap, forKey: "inputDisplacementImage")
        distortionFilter.setValue(finiteExtent.height * 0.04, forKey: kCIInputScaleKey)
        
        return distortionFilter.outputImage?.cropped(to: finiteExtent) ?? inputImage
    }
}
