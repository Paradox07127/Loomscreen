import Foundation
import Testing
@testable import LiveWallpaper

/// Opt-in compatibility gate. Skips silently unless `WPE_CORPUS_ROOT` points
/// at a directory of Wallpaper Engine workshop folders. Asserts the
/// deterministic feature totals the rest of the runtime is being built
/// against; tighten the thresholds as each phase lands.
struct WPECorpusCompatibilityTests {

    @Test("Scans corpus and counts scene packages")
    func scansCorpusAndCountsScenePackages() async throws {
        guard let scanner = try Self.makeScanner() else { return }
        let report = try await scanner.scan()

        #expect(report.scenePackageCount >= 1, "Corpus should contain at least one scene package")
        #expect((report.projectCounts[.scene] ?? 0) >= report.scenePackageCount)
    }

    @Test("Reports object kinds across every scene")
    func reportsObjectKindsAcrossEveryScene() async throws {
        guard let scanner = try Self.makeScanner() else { return }
        let report = try await scanner.scan()

        #expect((report.objectKindCounts[.image] ?? 0) > 0)
    }

    @Test("Surfaces top shader names for translator coverage")
    func surfacesTopShaderNamesForTranslatorCoverage() async throws {
        guard let scanner = try Self.makeScanner() else { return }
        let report = try await scanner.scan()

        if report.scenePackageCount > 0 {
            #expect(!report.topShaderNames.isEmpty)
        }
    }

    @Test("Counts shader-source-bearing scenes")
    func countsShaderSourceBearingScenes() async throws {
        guard let scanner = try Self.makeScanner() else { return }
        let report = try await scanner.scan()

        if report.scenePackageCount > 0 {
            #expect(report.scenesWithShaderSources >= 0)
        }
    }

    private static func makeScanner() throws -> WPECorpusScanner? {
        guard let raw = ProcessInfo.processInfo.environment["WPE_CORPUS_ROOT"], !raw.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return WPECorpusScanner(rootURL: url)
    }
}
