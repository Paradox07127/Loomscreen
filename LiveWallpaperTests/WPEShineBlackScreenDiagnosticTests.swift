#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Regression gate for the 3526278753 ("fate saber sleeping") full-screen
/// black-out.
///
/// Root cause: `WPEMetalShaderDispatcher.dispatchCustomShader` resolved texture
/// slots as `pass.pass.binds[slot] ?? textureBindings[slot] ?? …`. The raw
/// `binds` carry the effect's literal `{name:"previous"}`, which resolves to the
/// black "bootstrap previous" texture on a target with no prior-frame history.
/// `shine_combine` binds its slot-1 albedo (the image being lit) as `previous`,
/// so the whole image layer composited to black while only the leaf particles —
/// drawn on a separately-allocated output — stayed visible. The pipeline
/// builder already normalizes `previous` → `pass.source` in `textureBindings`,
/// so the fix is to prefer `textureBindings` first (matching every other
/// dispatch path).
///
/// This test renders the user's REAL cached scene, so it is skipped when that
/// scene is absent (CI / other machines). It is a guard, not a fixture-backed
/// unit test, because the bug only reproduces with the real shine effect graph.
@Suite("WPE shine black-screen regression (3526278753)")
struct WPEShineBlackScreenDiagnosticTests {

    private static var sceneCacheRoot: URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let candidates = [
            appSupport?.appendingPathComponent("LiveWallpaper/wpe-cache/3526278753", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/LiveWallpaper/wpe-cache/3526278753", isDirectory: true),
            home.appendingPathComponent("Library/Containers/Taijia.LiveWallpaper/Data/Library/Application Support/LiveWallpaper/wpe-cache/3526278753", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { fileManager.fileExists(atPath: $0.appendingPathComponent("scene.json").path) }
    }

    @MainActor
    @Test("Saber image layer composites to scene (not black) through the shine chain")
    func saberShineChainIsNotBlack() async throws {
        guard let cacheRoot = Self.sceneCacheRoot else {
            print("[shine-regression] real 3526278753 cache absent — skipping")
            return
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = SceneDescriptor(
            workshopID: "3526278753",
            cacheRelativePath: "wpe-cache/3526278753",
            entryFile: "scene.json",
            capabilityTier: .degraded
        )
        let renderer = try WPEMetalSceneRenderer(
            descriptor: descriptor,
            cacheRootURL: cacheRoot,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
        try await renderer.load()

        let passCount = renderer.debugFirstLayerPassCount
        #expect(passCount > 0, "image layer should have render passes")

        // Render the full image-layer chain (foliagesway → waterwaves → shine
        // combine → scene). Before the fix this produced an all-black frame
        // (nonBlack == 0); the saber image must now cover the frame.
        let output = try renderer.debugRenderTruncated(passLimit: passCount)
        let stats = try #require(WPEMetalTextureVisualStats.analyze(texture: output))

        // A 4K opaque wallpaper should light up essentially the whole frame.
        let totalPixels = stats.width * stats.height
        #expect(
            stats.nonBlackPixelCount > totalPixels / 2,
            "shine chain output is mostly black (nonBlack=\(stats.nonBlackPixelCount)/\(totalPixels)) — regression of the binds/textureBindings precedence fix"
        )
        #expect(stats.nonBlackCoversFullFrame, "saber image should cover the full frame: \(stats.oneLineDescription)")

        // Cross-frame stability through the REAL renderCurrentFrame path, so
        // `previousFrameHistory` feedback accumulates exactly like on-device.
        // On-device symptom: frame 0 correct, frame 1 goes pure white.
        let textures = try renderer.debugRenderSuccessiveFrameTextures(6)
        try dumpFrames(textures, prefix: "3526278753")
        let frames: [(nonBlack: Double, white: Double, luma: Double)] = textures.map {
            WPEMetalSceneRenderer.debugFrameStats(of: $0)
        }
        let summary = frames.enumerated()
            .map { "f\($0.offset)(nb=\(pct($0.element.nonBlack)) white=\(pct($0.element.white)) luma=\(Int($0.element.luma)))" }
            .joined(separator: " ")
        // Encode the per-frame numbers in the assertion message so they survive
        // swift-testing's stdout buffering.
        #expect(frames.allSatisfy { $0.white < 0.5 }, "cross-frame white-out — \(summary)")
    }

    private func pct(_ v: Double) -> String { String(format: "%.2f", v) }

    private func dumpFrames(_ textures: [MTLTexture], prefix: String) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let outputDirectory = support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("diagnostic-frames", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for (index, texture) in textures.enumerated() {
            guard let image = WPEMetalTextureSnapshotter.shared.snapshot(from: texture),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                continue
            }
            let url = outputDirectory.appendingPathComponent("\(prefix)-frame-\(index).png")
            try png.write(to: url, options: .atomic)
        }
        print("[shine-regression] dumped frames to \(outputDirectory.path)")
    }
}
#endif
