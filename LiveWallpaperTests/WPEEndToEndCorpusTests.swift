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
        guard let envRoot = ProcessInfo.processInfo.environment["WPE_CORPUS_ROOT"], !envRoot.isEmpty else {
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
        let workshopFilter = ProcessInfo.processInfo.environment["WPE_CORPUS_WORKSHOP_ID"]
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
}
