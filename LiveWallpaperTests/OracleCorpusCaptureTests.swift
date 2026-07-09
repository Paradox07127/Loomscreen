#if !LITE_BUILD
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// Headless oracle capture: drives real workshop scenes through the production
/// `WPEMetalSceneRenderer.load()` pipeline OFF the GUI (offscreen Metal, no window),
/// with the render oracle forced on, so each scene writes a deterministic
/// `WPECanonicalTraceRecorder` trace. Run it on the pre-refactor build → a `before`
/// label, then on the post-refactor build → `after`, then `oracle.py self-batch` — no
/// manual per-scene clicking.
///
/// Config comes from a JSON file inside the app's container (xcodebuild does not forward
/// shell env to the sandboxed test runner, and the sandbox only lets the test read/write
/// its own container). Write it before running, e.g.:
///
///     <container>/Application Support/LiveWallpaper/oracle-capture.json
///     { "corpusRoot": "…/workshop/content/431960", "label": "before",
///       "scenes": ["3554161528"] }   // "scenes" optional = whole corpus
///
/// Traces land in `<container>/…/LiveWallpaper/oracle-out/<label>/<id>.json`. Absent
/// config ⇒ the test skips cleanly, so it never runs in the normal suite.
@Suite("Oracle corpus capture")
struct OracleCorpusCaptureTests {

    private struct Config: Codable {
        let corpusRoot: String
        var label: String = "capture"
        var scenes: [String]?
        /// Opt-in per-pass hashing (slow) — for LOCATING which pass first diverges.
        var perPass: Bool = false
    }

    @MainActor
    @Test("Capture oracle traces for a scene corpus (opt-in via container config file)")
    func captureCorpus() async throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("LiveWallpaper")
        let configURL = base.appendingPathComponent("oracle-capture.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data),
              !config.corpusRoot.isEmpty else {
            print("[oracle-capture] no \(configURL.path) — skipping.")
            return
        }
        let root = URL(fileURLWithPath: config.corpusRoot)
        // NOT wiped between invocations: the corpus runs one scene PER PROCESS (fresh GPU
        // memory ⇒ deterministic — multi-scene-per-process inherits non-deterministic
        // residue in unwritten FBO regions), so successive single-scene runs accumulate
        // into the same label dir. Per-scene `<id>.json` is overwritten below.
        let outDir = base.appendingPathComponent("oracle-out").appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let filter = config.scenes.map(Set.init)
        print("[oracle-capture] config: corpusRoot=\(config.corpusRoot) label=\(config.label) scenes=\(config.scenes ?? ["<all>"])")

        // Force the oracle on for this run regardless of the machine default (seeds
        // particles, freezes the clock, writes the canonical trace).
        WPEOracleMode.testingOverride = true
        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        if config.perPass {
            UserDefaults.standard.set(true, forKey: "WPEOraclePerPassHashes")
        }
        defer {
            WPEOracleMode.testingOverride = nil
            WPESceneDebugArtifacts.shared.setEnabledForTesting(nil)
            if config.perPass {
                UserDefaults.standard.removeObject(forKey: "WPEOraclePerPassHashes")
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
                try await renderer.load()
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

    /// Newest `scene-debug/<stamp>-<id>/trace.json` the recorder just wrote for this scene.
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
