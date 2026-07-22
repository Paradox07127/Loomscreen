#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal
import Testing
@testable import LiveWallpaper

@Suite("Oracle corpus capture")
struct OracleCorpusCaptureTests {

    private struct Config: Codable {
        let corpusRoot: String
        var label: String = "capture"
        var scenes: [String]?
        var perPass: Bool = false
        var dumpPNGs: Bool = false
        var frames: Int = 1
        var frameStepSeconds: Double = 1.0 / 60.0

        private enum CodingKeys: String, CodingKey {
            case corpusRoot, label, scenes, perPass, dumpPNGs, frames, frameStepSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corpusRoot = try container.decode(String.self, forKey: .corpusRoot)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? "capture"
            scenes = try container.decodeIfPresent([String].self, forKey: .scenes)
            perPass = try container.decodeIfPresent(Bool.self, forKey: .perPass) ?? false
            dumpPNGs = try container.decodeIfPresent(Bool.self, forKey: .dumpPNGs) ?? false
            frames = try container.decodeIfPresent(Int.self, forKey: .frames) ?? 1
            frameStepSeconds = try container.decodeIfPresent(Double.self, forKey: .frameStepSeconds) ?? (1.0 / 60.0)
        }
    }

    @MainActor
    @Test("Capture oracle traces for a scene corpus (opt-in via container config file)")
    func captureCorpus() async throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("LiveWallpaper")
        let configURL = base.appendingPathComponent("oracle-capture.json")
        guard let data = try? Data(contentsOf: configURL) else {
            print("[oracle-capture] no \(configURL.path) — skipping.")
            return
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        try #require(!config.corpusRoot.isEmpty, "oracle-capture.json corpusRoot must not be empty")
        let root = URL(fileURLWithPath: config.corpusRoot)
        let outDir = base.appendingPathComponent("oracle-out").appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let filter = config.scenes.map(Set.init)
        print("[oracle-capture] config: corpusRoot=\(config.corpusRoot) label=\(config.label) "
              + "scenes=\(config.scenes ?? ["<all>"]) frames=\(config.frames) step=\(config.frameStepSeconds)")

        WPEOracleMode.testingOverride = true
        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        if config.perPass {
            UserDefaults.standard.set(true, forKey: "WPEOraclePerPassHashes")
        }
        defer {
            WPEOracleMode.testingOverride = nil
            WPEOracleMode.frameAdvanceSeconds = 0
            WPESceneDebugArtifacts.shared.setEnabledForTesting(nil)
            if config.perPass {
                UserDefaults.standard.removeObject(forKey: "WPEOraclePerPassHashes")
            }
            if config.dumpPNGs {
                UserDefaults.standard.removeObject(forKey: "WPEDumpScenePasses")
            }
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let engineAssetsRoot = WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var captured = 0, skipped = 0, failed = 0
        for folder in folders {
            let id = folder.lastPathComponent
            if let filter, !filter.contains(id) { continue }
            guard let project = try? WallpaperEngineProject.read(from: folder), project.type == .scene else {
                skipped += 1
                continue
            }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("wpe-oracle-\(id)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let pkgURL = folder.appendingPathComponent("scene.pkg")
                if FileManager.default.fileExists(atPath: pkgURL.path) {
                    let handle = try FileHandle(forReadingFrom: pkgURL)
                    defer { try? handle.close() }
                    let pkg = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
                    try pkg.extractAll(streamingFrom: handle, to: stage)
                } else {
                    for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                        try FileManager.default.copyItem(at: item, to: stage.appendingPathComponent(item.lastPathComponent))
                    }
                }
            } catch {
                print("[oracle-capture] [\(id)] extract failed: \(error)")
                failed += 1
                continue
            }

            if config.dumpPNGs {
                UserDefaults.standard.set(id, forKey: "WPEDumpScenePasses")
            }
            WPEOracleMode.frameAdvanceSeconds = 0
            let descriptor = SceneDescriptor(
                workshopID: id,
                cacheRelativePath: "wpe-oracle-cache/\(id)",
                entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile,
                capabilityTier: .degraded
            )
            do {
                let renderer = try WPEMetalSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: stage,
                    dependencyMounts: [],
                    engineAssetsRootURL: engineAssetsRoot,
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    device: device,
                    pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
                )
                let renderActor = WPEDisplayRenderActor(backing: .main)
                await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
                try await renderActor.load()
                try Self.advanceToTracedFrame(
                    renderer: renderer,
                    id: id,
                    entryFile: descriptor.entryFile,
                    stage: stage,
                    frames: config.frames,
                    stepSeconds: config.frameStepSeconds,
                    perPass: config.perPass || config.dumpPNGs
                )
                if let trace = Self.latestTrace(forID: id) {
                    let dest = outDir.appendingPathComponent("\(id).json")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: trace, to: dest)
                    captured += 1
                    print("[oracle-capture] [\(id)] ✅ trace → \(dest.lastPathComponent)")
                } else {
                    print("[oracle-capture] [\(id)] loaded but no trace written")
                    failed += 1
                }
            } catch {
                print("[oracle-capture] [\(id)] load failed: \(String(describing: error).prefix(200))")
                failed += 1
            }
        }
        print("=== oracle-capture: captured=\(captured) skipped=\(skipped) failed=\(failed) → \(outDir.path) ===")
        #expect(captured > 0, "no scene produced a trace — check corpus root / engine assets")
    }

    @Test("Config decode fills in defaults for keys a config file omits")
    func configDecodeFillsDefaultsForMissingKeys() throws {
        let json = Data(#"{"corpusRoot": "/tmp/corpus"}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.corpusRoot == "/tmp/corpus")
        #expect(config.label == "capture")
        #expect(config.scenes == nil)
        #expect(config.perPass == false)
        #expect(config.dumpPNGs == false)
        #expect(config.frames == 1)
        #expect(config.frameStepSeconds == 1.0 / 60.0)
    }

    @Test("Config decode accepts an explicit multi-frame capture")
    func configDecodeAcceptsFrames() throws {
        let json = Data(#"{"corpusRoot": "/tmp/corpus", "frames": 4, "frameStepSeconds": 0.5}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.frames == 4)
        #expect(config.frameStepSeconds == 0.5)
    }

    @Test("Frozen clock advances with frameAdvanceSeconds, and is inert at 0")
    func frozenClockAdvancesWithFrameAdvance() throws {
        WPEOracleMode.testingOverride = true
        defer {
            WPEOracleMode.testingOverride = nil
            WPEOracleMode.frameAdvanceSeconds = 0
        }
        WPEOracleMode.frameAdvanceSeconds = 0
        let override = try #require(WPEOracleMode.loadFrameOverride())
        let frozen = override.time
        #expect(override.time == override.baseTime, "advance 0 must leave the clock exactly frozen")

        WPEOracleMode.frameAdvanceSeconds = 0.25
        #expect(override.time == frozen + 0.25)
        #expect(override.baseTime == frozen)
    }

    @Test("Config decode throws on a malformed config instead of silently defaulting")
    func configDecodeThrowsOnMalformedConfig() {
        let missingCorpusRoot = Data(#"{"label": "oops"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: missingCorpusRoot)
        }

        let wrongShape = Data(#"{"corpusRoot": 12345}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: wrongShape)
        }
    }

    @MainActor
    private static func advanceToTracedFrame(
        renderer: WPEMetalSceneRenderer,
        id: String,
        entryFile: String,
        stage: URL,
        frames: Int,
        stepSeconds: Double,
        perPass: Bool
    ) throws {
        guard frames > 1 else { return }
        let summary = "\(id) oracle-capture frames=\(frames) step=\(stepSeconds)"
        for index in 1..<frames {
            WPEOracleMode.frameAdvanceSeconds = Double(index) * stepSeconds
            let isLast = index == frames - 1
            if isLast {
                _ = WPESceneDebugArtifacts.shared.beginSession(workshopID: id, descriptor: summary)
                WPECanonicalTraceRecorder.shared.beginScene(
                    workshopID: id,
                    projectJsonPath: stage.appendingPathComponent(entryFile).path,
                    descriptor: summary
                )
            }
            let texture = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            guard isLast else { continue }
            if perPass {
                renderer.dumpScenePassesIfRequested(suffix: "-f\(index)")
            }
            WPECanonicalTraceRecorder.shared.finishFrame(
                outputTexture: texture,
                runtimeUniforms: renderer.lastRuntimeUniforms,
                firstFrameStats: WPEMetalTextureVisualStats.analyze(texture: texture),
                resolutionDiagnostics: renderer.resolutionTracer.snapshot(),
                frameOrdinal: index
            )
            WPESceneDebugArtifacts.shared.endSession()
            print("[oracle-capture] [\(id)] advanced to frame \(index) "
                  + "(t=\(renderer.lastRuntimeUniforms.map { String(format: "%.4f", $0.time) } ?? "?"))")
        }
    }

    private static func latestTrace(forID id: String) -> URL? {
        guard let root = WPESceneDebugArtifacts.rootURL else { return nil }
        let sessions = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-\(id)") }
        let newest = sessions.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let session = newest else { return nil }
        let trace = session.appendingPathComponent("trace.json")
        return FileManager.default.fileExists(atPath: trace.path) ? trace : nil
    }
}
#endif
