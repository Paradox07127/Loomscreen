#if !LITE_BUILD
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Regression net for the flag-gated HDR present tonemap
/// (`WPEMetalHDRTonemapEnabled`, default OFF):
/// 1. the pure fragment selection — flag OFF or any SDR source must keep the
///    legacy fragment name (same pipeline-cache key ⇒ byte-identical path),
/// 2. the Swift curve (`WPEHDRTonemapCurve`) — <=1 passthrough, strict soft-knee
///    compression above 1, hue preservation, NaN/inf safety,
/// 3. GPU <-> CPU twins locked to the shared sample peaks 0.3 / 1.0 / 2.0 / 5.0:
///    the MSL fragment's output must match the Swift curve within half precision,
///    with <=1 pixels byte-identical to the legacy fragment's output,
/// 4. the snapshotter's rgba16Float conversion honoring the same curve when the
///    flag is on, so posters match the tonemapped screen.
@MainActor
@Suite("WPE HDR present tonemap")
struct WPEPresentTonemapTests {

    // MARK: - Fragment selection (the flag gate itself)

    @Test("Flag OFF selects the legacy fragment for every source format")
    func flagOffSelectsLegacyFragment() {
        let formats: [MTLPixelFormat] = [.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float]
        for format in formats {
            #expect(
                WPEMetalRenderExecutor.presentFragmentName(hdrTonemapEnabled: false, sourcePixelFormat: format)
                    == "wpe_present_fragment"
            )
        }
    }

    @Test("Flag ON selects the tonemap fragment only for rgba16Float (HDR) sources")
    func flagOnSelectsTonemapOnlyForHDR() {
        #expect(
            WPEMetalRenderExecutor.presentFragmentName(hdrTonemapEnabled: true, sourcePixelFormat: .rgba16Float)
                == "wpe_present_tonemap_fragment"
        )
        let sdrFormats: [MTLPixelFormat] = [.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb]
        for format in sdrFormats {
            #expect(
                WPEMetalRenderExecutor.presentFragmentName(hdrTonemapEnabled: true, sourcePixelFormat: format)
                    == "wpe_present_fragment"
            )
        }
    }

    // MARK: - Swift curve

    @Test("Peaks <= 1 pass through untouched (bit-exact identity)")
    func curvePassthroughBelowKnee() {
        #expect(WPEHDRTonemapCurve.scale(forPeak: 0.3) == 1)
        #expect(WPEHDRTonemapCurve.scale(forPeak: 1.0) == 1)
        #expect(WPEHDRTonemapCurve.scale(forPeak: 0) == 1)
        let samples: [SIMD3<Float>] = [
            SIMD3(0.3, 0.3, 0.3),
            SIMD3(1.0, 1.0, 1.0),
            SIMD3(1.0, 0.25, 0.0),
            SIMD3(0.0, 0.0, 0.0),
        ]
        for rgb in samples {
            #expect(WPEHDRTonemapCurve.apply(rgb) == rgb)
        }
    }

    @Test("Peaks > 1 compress strictly, monotonically, hue-preserving")
    func curveCompressesAboveKnee() {
        // Shared samples: peak 2 -> 2 - 1/2 = 1.5, peak 5 -> 2 - 1/5 = 1.8.
        let gray2 = WPEHDRTonemapCurve.apply(SIMD3<Float>(2, 2, 2))
        #expect(abs(gray2.x - 1.5) < 1e-6 && gray2.x == gray2.y && gray2.y == gray2.z)
        let gray5 = WPEHDRTonemapCurve.apply(SIMD3<Float>(5, 5, 5))
        #expect(abs(gray5.x - 1.8) < 1e-6)

        // Hue preservation: all channels scale by the same factor, so channel
        // ratios survive (the per-channel clamp would bleach this to yellow-white).
        let orange = WPEHDRTonemapCurve.apply(SIMD3<Float>(2, 0.5, 0))
        #expect(abs(orange.x - 1.5) < 1e-6)
        #expect(abs(orange.y - 0.375) < 1e-6)
        #expect(orange.z == 0)

        // Strictly increasing compressed peak, strictly decreasing scale.
        var previousPeak: Float = 1
        var previousScale: Float = 1
        for peak in stride(from: Float(1.01), through: 20, by: 0.37) {
            let scale = WPEHDRTonemapCurve.scale(forPeak: peak)
            let compressed = peak * scale
            #expect(scale < previousScale)
            #expect(compressed > previousPeak)
            #expect(compressed < 2, "asymptote is 2")
            previousPeak = compressed
            previousScale = scale
        }
    }

    @Test("Curve is NaN/inf safe")
    func curveNaNInfSafety() {
        #expect(WPEHDRTonemapCurve.scale(forPeak: .nan) == 1)
        // inf peak: the half-max guard keeps the scale finite and positive, so
        // finite channels stay finite (crushed toward 0) instead of going NaN.
        let inf = WPEHDRTonemapCurve.apply(SIMD3<Float>(.infinity, 0.5, 0.3))
        #expect(inf.x == .infinity)
        #expect(inf.y.isFinite && inf.y >= 0)
        #expect(inf.z.isFinite && inf.z >= 0)
    }

    // MARK: - GPU fragment vs Swift twin

    /// Shared sample pixels. Grays pin the curve at the approved peaks
    /// (0.3 / 1.0 / 2.0 / 5.0); the colored pixels pin hue preservation;
    /// zero pins the black point.
    private static let samplePixels: [SIMD3<Float>] = [
        SIMD3(0.3, 0.3, 0.3),
        SIMD3(1.0, 1.0, 1.0),
        SIMD3(2.0, 2.0, 2.0),
        SIMD3(5.0, 5.0, 5.0),
        SIMD3(2.0, 0.5, 0.0),
        SIMD3(5.0, 2.0, 0.5),
        SIMD3(0.0, 0.0, 0.0),
    ]

    private func makeSourceTexture(device: MTLDevice, pixels: [SIMD3<Float>]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: pixels.count,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var halves = [UInt16]()
        halves.reserveCapacity(pixels.count * 4)
        for pixel in pixels {
            halves.append(Float16(pixel.x).bitPattern)
            halves.append(Float16(pixel.y).bitPattern)
            halves.append(Float16(pixel.z).bitPattern)
            halves.append(Float16(1).bitPattern)
        }
        halves.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, pixels.count, 1),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: pixels.count * 8
            )
        }
        return texture
    }

    /// Runs the production present pipeline (same vertex + fit uniforms as
    /// `present()`) with the given fragment into a FLOAT target, so >1 values
    /// survive readback and "strictly compressed" is observable pre-clamp.
    private func renderPresent(
        executor: WPEMetalRenderExecutor,
        device: MTLDevice,
        source: MTLTexture,
        fragmentName: String
    ) throws -> [UInt16] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: descriptor))

        let state = try executor.renderPipeline(
            vertexName: "wpe_present_vertex",
            fragmentName: fragmentName,
            blendMode: "disabled",
            colorPixelFormat: target.pixelFormat
        )
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(state)
        encoder.setFragmentTexture(source, index: 0)
        var uniforms = WPEPresentUniforms.make(
            fitMode: .stretch,
            sourceWidth: source.width,
            sourceHeight: source.height,
            targetWidth: target.width,
            targetHeight: target.height
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<WPEPresentUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var halves = [UInt16](repeating: 0, count: target.width * 4)
        halves.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!,
                bytesPerRow: target.width * 8,
                from: MTLRegionMake2D(0, 0, target.width, 1),
                mipmapLevel: 0
            )
        }
        return halves
    }

    @Test("GPU tonemap fragment: <=1 byte-identical to legacy, >1 strictly compressed, matches the Swift twin")
    func gpuFragmentMatchesSwiftTwin() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pixels = Self.samplePixels
        let source = try makeSourceTexture(device: device, pixels: pixels)

        let legacy = try renderPresent(executor: executor, device: device, source: source, fragmentName: "wpe_present_fragment")
        let tonemapped = try renderPresent(executor: executor, device: device, source: source, fragmentName: "wpe_present_tonemap_fragment")

        for (index, pixel) in pixels.enumerated() {
            let base = index * 4
            let peak = max(pixel.x, max(pixel.y, pixel.z))
            let expected = WPEHDRTonemapCurve.apply(pixel)
            for channel in 0..<3 {
                let legacyBits = legacy[base + channel]
                let tonemapBits = tonemapped[base + channel]
                let legacyValue = Float(Float16(bitPattern: legacyBits))
                let tonemapValue = Float(Float16(bitPattern: tonemapBits))
                let sourceChannel = pixel[channel]

                // The legacy fragment is a pure copy: it must return the source bits.
                #expect(
                    legacyBits == Float16(sourceChannel).bitPattern,
                    "legacy present must be a bit-exact copy (pixel \(index) ch \(channel))"
                )

                if peak <= 1 {
                    #expect(
                        tonemapBits == legacyBits,
                        "<=1 peak must be a bit-exact passthrough (pixel \(index) ch \(channel))"
                    )
                } else if sourceChannel > 0 {
                    #expect(
                        tonemapValue < legacyValue,
                        "positive channel of a >1-peak pixel must be strictly compressed (pixel \(index) ch \(channel))"
                    )
                } else {
                    #expect(tonemapValue == 0, "zero channel stays zero (pixel \(index) ch \(channel))")
                }

                // GPU output must track the Swift twin within half precision.
                let tolerance = max(abs(expected[channel]) * 2e-3, 2e-3)
                #expect(
                    abs(tonemapValue - expected[channel]) <= tolerance,
                    "GPU/CPU divergence at pixel \(index) ch \(channel): gpu=\(tonemapValue) swift=\(expected[channel])"
                )
            }
            // Alpha is untouched by both fragments.
            #expect(tonemapped[base + 3] == legacy[base + 3])
        }
    }

    // MARK: - Snapshotter CPU path

    @Test("Snapshotter float conversion: flag OFF is the legacy clamp, flag ON matches the curve")
    func snapshotterConversionHonorsFlag() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pixels = Self.samplePixels
        let texture = try makeSourceTexture(device: device, pixels: pixels)

        let off = WPEMetalTextureSnapshotter.convertRGBA16FloatToSRGB8(texture, tonemapEnabled: false)
        let on = WPEMetalTextureSnapshotter.convertRGBA16FloatToSRGB8(texture, tonemapEnabled: true)

        func srgbByte(_ linear: Float) -> UInt8 {
            let clamped = linear.isFinite ? min(max(linear, 0), 1) : 0
            let encoded = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return UInt8(encoded * 255 + 0.5)
        }

        for (index, pixel) in pixels.enumerated() {
            let base = index * 4
            // The half round-trip through the texture is part of the real path.
            let stored = SIMD3<Float>(
                Float(Float16(pixel.x)),
                Float(Float16(pixel.y)),
                Float(Float16(pixel.z))
            )
            let curved = WPEHDRTonemapCurve.apply(stored)
            for channel in 0..<3 {
                #expect(off[base + channel] == srgbByte(stored[channel]), "flag OFF must stay the legacy clamp path")
                #expect(on[base + channel] == srgbByte(curved[channel]), "flag ON must run the shared curve first")
            }
            #expect(off[base + 3] == 255 && on[base + 3] == 255)
        }

        // The observable win: an overbright COLORED pixel keeps hue instead of
        // bleaching — its sub-peak channels come out strictly darker than clamp.
        let orangeBase = 4 * 4 // SIMD3(2.0, 0.5, 0.0)
        #expect(on[orangeBase + 1] < off[orangeBase + 1])
    }

    // MARK: - Float stats (evidence instrumentation)

    @Test("Float stats count overbright pixels and report the peak channel")
    func floatStatsAnalyzeOverbright() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let texture = try makeSourceTexture(device: device, pixels: Self.samplePixels)
        let stats = try #require(WPEMetalTextureFloatStats.analyze(texture: texture))
        // Pixels with any channel > 1: gray 2, gray 5, (2,0.5,0), (5,2,0.5).
        #expect(stats.overbrightPixelCount == 4)
        #expect(stats.maxChannelValue == 5)
        #expect(stats.width == Self.samplePixels.count && stats.height == 1)

        // Non-float textures are out of scope by contract.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let ldr = try #require(device.makeTexture(descriptor: descriptor))
        #expect(WPEMetalTextureFloatStats.analyze(texture: ldr) == nil)
    }
}
#endif
