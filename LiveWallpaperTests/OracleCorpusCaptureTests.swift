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
        /// Opt-in per-pass PNG dumps (`WPEDumpScenePasses` semantics, but set from
        /// INSIDE the test host — an outside `defaults write` to the container plist
        /// is a different cfprefsd domain and the sandboxed host never sees it).
        var dumpPNGs: Bool = false
        /// Opt-in `WPEMetalHDRTonemapEnabled` for headless tonemap A/B evidence runs
        /// (same sandbox reason as `dumpPNGs`: the flag must be set in-process).
        var hdrTonemap: Bool = false

        private enum CodingKeys: String, CodingKey {
            case corpusRoot, label, scenes, perPass, dumpPNGs, hdrTonemap
        }

        /// Swift's compiler-synthesized `Decodable.init(from:)` does NOT fall back to a
        /// property's `= default` for a missing key on a non-Optional field — it throws
        /// `keyNotFound` instead. A config JSON written before `perPass`/`dumpPNGs`
        /// existed (or hand-edited without them) would therefore fail to decode, and
        /// the caller's `try?` turned that into a silent "no config — skipping", so the
        /// capture never ran yet the test still passed. This hand-written initializer
        /// applies the intended defaults via `decodeIfPresent` instead.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corpusRoot = try container.decode(String.self, forKey: .corpusRoot)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? "capture"
            scenes = try container.decodeIfPresent([String].self, forKey: .scenes)
            perPass = try container.decodeIfPresent(Bool.self, forKey: .perPass) ?? false
            dumpPNGs = try container.decodeIfPresent(Bool.self, forKey: .dumpPNGs) ?? false
            hdrTonemap = try container.decodeIfPresent(Bool.self, forKey: .hdrTonemap) ?? false
        }
    }

    @MainActor
    @Test("Capture oracle traces for a scene corpus (opt-in via container config file)")
    func captureCorpus() async throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("LiveWallpaper")
        let configURL = base.appendingPathComponent("oracle-capture.json")
        // Absent file ⇒ this is the normal (non-opt-in) test run: skip cleanly, never
        // fail the suite. A file that EXISTS but fails to decode is a real
        // misconfiguration (typo'd key, wrong JSON shape) — let it throw so the test
        // FAILS loudly instead of silently no-op'ing like a missing file would.
        guard let data = try? Data(contentsOf: configURL) else {
            print("[oracle-capture] no \(configURL.path) — skipping.")
            return
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        try #require(!config.corpusRoot.isEmpty, "oracle-capture.json corpusRoot must not be empty")
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
        if config.hdrTonemap {
            // Must land before anything touches the frozen
            // `WPEHDRTonemapCurve.isEnabled` static.
            UserDefaults.standard.set(true, forKey: "WPEMetalHDRTonemapEnabled")
        }
        defer {
            WPEOracleMode.testingOverride = nil
            WPESceneDebugArtifacts.shared.setEnabledForTesting(nil)
            if config.perPass {
                UserDefaults.standard.removeObject(forKey: "WPEOraclePerPassHashes")
            }
            if config.dumpPNGs {
                UserDefaults.standard.removeObject(forKey: "WPEDumpScenePasses")
            }
            if config.hdrTonemap {
                UserDefaults.standard.removeObject(forKey: "WPEMetalHDRTonemapEnabled")
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

    @Test("Config decode fills in defaults for keys a config file omits")
    func configDecodeFillsDefaultsForMissingKeys() throws {
        // Only corpusRoot — the shape of a config written before perPass/dumpPNGs/label
        // existed. Must decode, not throw, with every omitted field at its intended default.
        let json = Data(#"{"corpusRoot": "/tmp/corpus"}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.corpusRoot == "/tmp/corpus")
        #expect(config.label == "capture")
        #expect(config.scenes == nil)
        #expect(config.perPass == false)
        #expect(config.dumpPNGs == false)
        #expect(config.hdrTonemap == false)
    }

    @Test("Config decode throws on a malformed config instead of silently defaulting")
    func configDecodeThrowsOnMalformedConfig() {
        // corpusRoot is required with no default; a config file that exists but omits
        // it (or has the wrong shape) must fail to decode so the caller's `try` — no
        // longer swallowed by `try?` — turns it into a real test failure, not the
        // same silent skip as a plain missing file.
        let missingCorpusRoot = Data(#"{"label": "oops"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: missingCorpusRoot)
        }

        let wrongShape = Data(#"{"corpusRoot": 12345}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: wrongShape)
        }
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
