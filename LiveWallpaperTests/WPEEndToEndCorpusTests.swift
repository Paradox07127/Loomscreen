import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
@testable import LiveWallpaper

/// End-to-end pipeline gate: extracts every scene package in
/// `WPE_CORPUS_ROOT`, runs each through the production
/// `WPEMetalSceneRenderer.load()` pipeline (parse → graph → pipeline
/// → texture load → first-frame render), and reports per-scene success
/// or the precise error class. Pure measurement — no assertions on
/// pass count, just diagnostics. Run via:
///
///     WPE_CORPUS_ROOT='/path/to/431960' \
///     xcodebuild test -only-testing:LiveWallpaperTests/WPEEndToEndCorpusTests
///
/// The harness env var doesn't always propagate; if it doesn't, the
/// test logs that fact and exits cleanly so CI stays green.
struct WPEEndToEndCorpusTests {

    @MainActor
    @Test("Every corpus scene reaches first frame or surfaces a precise error")
    func everyCorpusSceneRunsThroughPipeline() async throws {
        guard let envRoot = Self.configuredString(
            environmentKey: "WPE_CORPUS_ROOT",
            fileName: "loomscreen-wpe-corpus-root"
        ) else {
            print("[corpus] WPE_CORPUS_ROOT not set — skipping (sandbox prevents arbitrary-path access from xcodebuild test harness)")
            return
        }
        let root = URL(fileURLWithPath: envRoot, isDirectory: true)
        let probeOK = await Self.probeReadable(root, timeoutSeconds: 2)
        guard probeOK else {
            print("[corpus] root '\(envRoot)' is not readable from this sandbox — skipping")
            return
        }
        print("[corpus] sourcing scenes from \(envRoot)")
        let workshopFilter = Self.configuredString(
            environmentKey: "WPE_CORPUS_WORKSHOP_ID",
            fileName: "loomscreen-wpe-corpus-workshop-id"
        )
            .map { value in
                Set(value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            }
            .flatMap { $0.isEmpty ? nil : $0 }
        if let workshopFilter {
            print("[corpus] filtering workshop IDs: \(workshopFilter.sorted().joined(separator: ","))")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[corpus] no Metal device — skipping")
            return
        }

        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            ?? []
        var summary: [(workshop: String, status: String, detail: String)] = []
        var rendered = 0
        var diagnosticOnly = 0
        var hardFailures = 0
        var skippedNonScene = 0

        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let workshopID = folder.lastPathComponent
            if let workshopFilter, !workshopFilter.contains(workshopID) {
                continue
            }
            guard let project = try? WallpaperEngineProject.read(from: folder),
                  project.type == .scene else {
                skippedNonScene += 1
                continue
            }
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("wpe-e2e-\(workshopID)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                print("[corpus] [\(workshopID)] extract begin")
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let pkgURL = folder.appendingPathComponent("scene.pkg")
                if FileManager.default.fileExists(atPath: pkgURL.path) {
                    let handle = try FileHandle(forReadingFrom: pkgURL)
                    defer { try? handle.close() }
                    let pkg = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
                    try pkg.extractAll(streamingFrom: handle, to: stage)
                } else {
                    let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    for item in items {
                        try FileManager.default.copyItem(
                            at: item,
                            to: stage.appendingPathComponent(item.lastPathComponent)
                        )
                    }
                }
                print("[corpus] [\(workshopID)] extract done")
            } catch {
                hardFailures += 1
                summary.append((workshopID, "extract_failed", String(describing: error)))
                continue
            }

            let descriptor = SceneDescriptor(
                workshopID: workshopID,
                cacheRelativePath: "wpe-e2e-cache/\(workshopID)",
                entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile,
                capabilityTier: .imageOnly
            )
            let renderer: WPEMetalSceneRenderer
            do {
                print("[corpus] [\(workshopID)] renderer init begin")
                renderer = try WPEMetalSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: stage,
                    dependencyMounts: [],
                    frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                    device: device,
                    pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
                )
                print("[corpus] [\(workshopID)] renderer init done")
            } catch {
                hardFailures += 1
                summary.append((workshopID, "renderer_init_failed", String(describing: error)))
                continue
            }

            do {
                print("[corpus] [\(workshopID)] load begin")
                try await renderer.load()
                print("[corpus] [\(workshopID)] load done")
                if renderer.renderedTexture != nil {
                    rendered += 1
                    summary.append((workshopID, "rendered", "first frame produced"))
                } else if let diag = renderer.loadDiagnostics {
                    diagnosticOnly += 1
                    summary.append((workshopID, "diagnostic", String(describing: diag)))
                } else {
                    diagnosticOnly += 1
                    summary.append((workshopID, "no_texture", "load completed but no output texture"))
                }
            } catch {
                hardFailures += 1
                summary.append((workshopID, "load_threw", String(describing: error).prefix(200).description))
            }
        }

        print("=== Corpus end-to-end pipeline ===")
        print("Scene packages: \(summary.count) (skipped non-scene: \(skippedNonScene))")
        print("Rendered first frame: \(rendered)")
        print("Diagnostic-only (parsed but no render): \(diagnosticOnly)")
        print("Hard failures (extract/init/throw): \(hardFailures)")
        print("")
        print("Per-scene outcomes (sorted by status):")
        for entry in summary.sorted(by: { $0.status < $1.status || ($0.status == $1.status && $0.workshop < $1.workshop) }) {
            print("  [\(entry.status)] \(entry.workshop) — \(entry.detail.prefix(180))")
        }
        #expect(rendered + diagnosticOnly + hardFailures == summary.count)
    }

    @MainActor
    @Test("Focused visual gate keeps smaller object from covering full frame")
    func focusedVisualGateKeepsSmallerObjectFromCoveringFullFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try Self.makeSmallObjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )

        try await renderer.load()

        let texture = try #require(renderer.renderedTexture)
        let stats = try #require(WPEMetalTextureVisualStats.analyze(texture: texture))
        let bounds = try #require(stats.nonBlackBounds)

        #expect(stats.nonBlackPixelCount > 0)
        #expect(!bounds.coversFullFrame(width: stats.width, height: stats.height))
        #expect(bounds.width <= 32)
        #expect(bounds.height <= 32)
        #expect(renderer.resolutionDiagnostics.resolvedCount > 0)
        #expect(renderer.resolutionDiagnostics.missedRefs.isEmpty)
    }

    @MainActor
    @Test("Rotated non-square quads apply size before rotation")
    func rotatedNonSquareQuadsApplySizeBeforeRotation() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try Self.makeRotatedNonSquareFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor,
            cacheRootURL: fixture.root,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )

        try await renderer.load()

        let texture = try #require(renderer.renderedTexture)
        let centerLeftBlackPixels = Self.countPixels(
            in: texture,
            xRange: 0..<12,
            yRange: 27..<37
        ) { r, g, b, a in
            a > 240 && r < 8 && g < 8 && b < 8
        }

        #expect(centerLeftBlackPixels == 0)
    }

    @MainActor
    @Test("Selected corpus scene renders measurable first-frame diagnostics")
    func selectedCorpusSceneRendersMeasurableFirstFrameDiagnostics() async throws {
        guard let rootPath = Self.configuredString(
            environmentKey: "WPE_CORPUS_ROOT",
            fileName: "loomscreen-wpe-corpus-root"
        ) else {
            print("[corpus.visual] root not configured — skipping selected-scene visual gate")
            return
        }
        let workshopID = Self.configuredString(
            environmentKey: "WPE_CORPUS_VISUAL_WORKSHOP_ID",
            fileName: "loomscreen-wpe-corpus-visual-workshop-id"
        ) ?? Self.configuredString(
            environmentKey: "WPE_CORPUS_WORKSHOP_ID",
            fileName: "loomscreen-wpe-corpus-workshop-id"
        ) ?? "3287199039"
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let folder = root.appendingPathComponent(workshopID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            Issue.record("[corpus.visual] selected scene \(workshopID) is missing under \(rootPath)")
            return
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try await Self.makeCorpusRenderer(
            folder: folder,
            workshopID: workshopID,
            device: device
        )

        try await renderer.load()

        let texture = try #require(renderer.renderedTexture)
        let stats = try #require(WPEMetalTextureVisualStats.analyze(texture: texture))
        let resolution = renderer.resolutionDiagnostics

        print("[corpus.visual] \(workshopID) \(stats.oneLineDescription)")
        if !resolution.missedRefs.isEmpty {
            let misses = resolution.missedRefs.prefix(8)
                .map { "\($0.ref)=\($0.finalOutcome.debugLabel)" }
                .joined(separator: ", ")
            print("[corpus.visual] non-fatal resolver misses: \(misses)")
        }
        #expect(stats.nonBlackPixelCount > 0)
        #expect(resolution.resolvedCount > 0)
        if Self.configuredString(
            environmentKey: "WPE_CORPUS_VISUAL_STRICT_RESOLUTION",
            fileName: "loomscreen-wpe-corpus-visual-strict-resolution"
        ) == "1" {
            #expect(resolution.missedRefs.isEmpty)
        }
        #expect(renderer.loadDiagnostics == nil)
    }

    /// Sandbox-safe directory probe.
    static func probeReadable(_ url: URL, timeoutSeconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )) != nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return false
        }
    }

    private static func configuredString(
        environmentKey: String,
        fileName: String
    ) -> String? {
        if let value = ProcessInfo.processInfo.environment[environmentKey]
            .map(trimmedNonEmpty),
           let value {
            return value
        }
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return trimmedNonEmpty(raw)
    }

    private static func trimmedNonEmpty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @MainActor
    private static func makeCorpusRenderer(
        folder: URL,
        workshopID: String,
        device: MTLDevice
    ) async throws -> WPEMetalSceneRenderer {
        let project = try WallpaperEngineProject.read(from: folder)
        #expect(project.type == .scene)
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-visual-\(workshopID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let pkgURL = folder.appendingPathComponent("scene.pkg")
        if FileManager.default.fileExists(atPath: pkgURL.path) {
            let handle = try FileHandle(forReadingFrom: pkgURL)
            defer { try? handle.close() }
            let pkg = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            try pkg.extractAll(streamingFrom: handle, to: stage)
        } else {
            let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for item in items {
                try FileManager.default.copyItem(
                    at: item,
                    to: stage.appendingPathComponent(item.lastPathComponent)
                )
            }
        }
        return try WPEMetalSceneRenderer(
            descriptor: SceneDescriptor(
                workshopID: workshopID,
                cacheRelativePath: "wpe-visual-cache/\(workshopID)",
                entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile,
                capabilityTier: .imageOnly
            ),
            cacheRootURL: stage,
            dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 128, height: 128),
            device: device,
            pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
        )
    }

    private static func makeSmallObjectFixture() throws -> (root: URL, descriptor: SceneDescriptor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalVisualGate-\(UUID().uuidString)", isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let materials = root.appendingPathComponent("materials", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Self.writePNG(
            at: materials.appendingPathComponent("base.png"),
            color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
        try Data(#"{ "material": "materials/base.json" }"#.utf8)
            .write(to: models.appendingPathComponent("base.json"))
        try Data(#"{ "passes": [{ "shader": "genericimage2", "textures": ["materials/base.png"] }] }"#.utf8)
            .write(to: materials.appendingPathComponent("base.json"))
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": {
            "clearenabled": true,
            "clearcolor": "0 0 0",
            "orthogonalprojection": { "width": 64, "height": 64, "auto": true }
          },
          "objects": [{
            "id": "image",
            "name": "Small Image",
            "type": "image",
            "image": "models/base.json",
            "origin": "32 32 0",
            "size": "24 24",
            "scale": "1 1 1",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return (
            root,
            SceneDescriptor(
                workshopID: "visual-gate-\(UUID().uuidString)",
                cacheRelativePath: "wpe-cache/visual-gate",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }

    private static func makeRotatedNonSquareFixture() throws -> (root: URL, descriptor: SceneDescriptor) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEMetalRotatedQuad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scene = """
        {
          "camera": { "center": "0 0 0" },
          "general": {
            "clearenabled": true,
            "clearcolor": "0.2 0.4 0.8",
            "orthogonalprojection": { "width": 64, "height": 64, "auto": true }
          },
          "objects": [{
            "id": "bg",
            "name": "Background",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "0.2 0.4 0.8",
            "origin": "32 32 0",
            "size": "64 64",
            "scale": "1 1 1",
            "alpha": 1
          }, {
            "id": "rotated",
            "name": "Rotated Mask",
            "type": "image",
            "image": "models/util/solidlayer.json",
            "color": "0 0 0",
            "origin": "-10 32 0",
            "size": "40 8",
            "scale": "1 1 1",
            "angles": "0 0 1.57079632679",
            "alpha": 1
          }]
        }
        """
        try Data(scene.utf8).write(to: root.appendingPathComponent("scene.json"))
        return (
            root,
            SceneDescriptor(
                workshopID: "rotated-quad-\(UUID().uuidString)",
                cacheRelativePath: "wpe-cache/rotated-quad",
                entryFile: "scene.json",
                capabilityTier: .imageOnly
            )
        )
    }

    private static func writePNG(at url: URL, color: CGColor) throws {
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "visual-gate", code: -1)
        }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw NSError(domain: "visual-gate", code: -2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "visual-gate", code: -3)
        }
    }

    private static func countPixels(
        in texture: MTLTexture,
        xRange: Range<Int>,
        yRange: Range<Int>,
        matching predicate: (_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Bool
    ) -> Int {
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        var count = 0
        for y in yRange where y >= 0 && y < texture.height {
            for x in xRange where x >= 0 && x < texture.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if predicate(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]) {
                    count += 1
                }
            }
        }
        return count
    }
}
