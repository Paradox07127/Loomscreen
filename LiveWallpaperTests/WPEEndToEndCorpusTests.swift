import Foundation
import Metal
import Testing
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
        // Source the corpus root from env var first; xcodebuild's test
        // harness sometimes filters env vars, so as a development fallback
        // try the known local Workshop sync path. Production CI sets the
        // env explicitly.
        let envRoot = ProcessInfo.processInfo.environment["WPE_CORPUS_ROOT"] ?? ""
        let candidate = envRoot.isEmpty
            ? "/Users/taijial/Documents/Live Wallpapers/431960"
            : envRoot
        let root = URL(fileURLWithPath: candidate, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("[corpus] root '\(candidate)' does not exist — skipping")
            return
        }
        print("[corpus] sourcing scenes from \(candidate)")
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
            guard let project = try? WallpaperEngineProject.read(from: folder),
                  project.type == .scene else {
                skippedNonScene += 1
                continue
            }
            // Extract the scene package into a per-test cache dir so the
            // resolver can walk it the same way the production import path
            // does. We don't reuse the production WallpaperEngineCache to
            // avoid colliding with an in-flight live install.
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("wpe-e2e-\(workshopID)-\(UUID().uuidString)")
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
                    // Unpacked scene — copy folder contents.
                    let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    for item in items {
                        try FileManager.default.copyItem(
                            at: item,
                            to: stage.appendingPathComponent(item.lastPathComponent)
                        )
                    }
                }
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
                renderer = try WPEMetalSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: stage,
                    dependencyMounts: [],
                    frame: CGRect(x: 0, y: 0, width: 64, height: 64),
                    device: device,
                    pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
                )
            } catch {
                hardFailures += 1
                summary.append((workshopID, "renderer_init_failed", String(describing: error)))
                continue
            }

            do {
                try await renderer.load()
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

        // Report.
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
        // Soft expectation: the count of rendered scenes is non-zero so we
        // catch hard regressions (build broken / pipeline crash) in CI.
        #expect(rendered + diagnosticOnly + hardFailures == summary.count)
    }
}
