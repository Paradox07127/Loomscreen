@preconcurrency import AVFoundation
import CoreImage
import Metal

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
        // with -[... dictionaryRepresentation]: unrecognized selector). The deprecated
        // mutableCopy path is the ONLY working approach until Apple ships a CIFilter-aware
        // Configuration API. FB15823456 (radar filed).
        if let mutable = base.mutableCopy() as? AVMutableVideoComposition {
            mutable.frameDuration = frameDuration
            return mutable
        }
        return base
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
///
/// The displacement map is generated by a Metal **compute** shader
/// (`rainDisplacementCompute` in `Shaders.metal`), which replaces the
/// deprecated `CIColorKernel(source:)` CIKL string. The compute path
/// runs on the GPU and feeds a standard `CIDisplacementDistortion` filter.
class RainGlassFilter: CIFilter, @unchecked Sendable {
    @objc dynamic var inputImage: CIImage?
    @objc dynamic var inputTime: NSNumber = 0.0
    @objc dynamic var inputResolution: CIVector = CIVector(x: 1920, y: 1080)

    // MARK: - Metal pipeline (initialized once)

    private static let metalState: (MTLDevice, MTLCommandQueue, MTLComputePipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "rainDisplacementCompute"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue()
        else {
            Logger.error("RainGlassFilter: failed to create Metal compute pipeline", category: .videoPlayer)
            return nil
        }
        return (device, queue, pipeline)
    }()

    override var outputImage: CIImage? {
        guard let inputImage = inputImage else { return nil }
        guard let (device, queue, pipeline) = Self.metalState else {
            return inputImage // graceful degradation — no rain effect if Metal unavailable
        }

        let width = Int(inputResolution.x)
        let height = Int(inputResolution.y)
        let finiteExtent = CGRect(x: 0, y: 0, width: width, height: height)

        // Create a per-frame texture for the displacement map.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: desc) else { return inputImage }

        // Encode the compute pass.
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder()
        else { return inputImage }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)

        var time = inputTime.floatValue
        encoder.setBytes(&time, length: MemoryLayout<Float>.size, index: 0)
        var res = SIMD2<Float>(Float(width), Float(height))
        encoder.setBytes(&res, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        // Synchronous wait is acceptable here — this runs inside the
        // AVVideoComposition handler on a background thread, and the GPU
        // compute for a simple procedural shader is sub-millisecond.
        buffer.commit()
        buffer.waitUntilCompleted()

        // Wrap the texture as CIImage. Metal textures have y-down by default;
        // flip so it aligns with CI's y-up coordinate space.
        guard var displacementMap = CIImage(mtlTexture: texture, options: nil) else {
            return inputImage
        }
        displacementMap = displacementMap.oriented(.downMirrored)

        // Apply CIDisplacementDistortion — scale is resolution-relative.
        let distortion = CIFilter(name: "CIDisplacementDistortion")!
        distortion.setValue(inputImage, forKey: kCIInputImageKey)
        distortion.setValue(displacementMap, forKey: "inputDisplacementImage")
        distortion.setValue(finiteExtent.height * 0.04, forKey: kCIInputScaleKey)

        return distortion.outputImage?.cropped(to: finiteExtent) ?? inputImage
    }
}
