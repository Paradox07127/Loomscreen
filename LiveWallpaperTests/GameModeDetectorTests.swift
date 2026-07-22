import Foundation
import Testing
@testable import LiveWallpaper

/// Verifies category-based game detection; install paths are intentionally not classification signals.
@Suite("GameModeDetector classification")
struct GameModeDetectorTests {

    @Test("A declared game category classifies as game and pauses")
    func declaredGameCategoryIsGame() {
        #expect(GameModeDetector.classification(forCategory: "public.app-category.games") == .game)
        #expect(GameModeDetector.classification(forCategory: "public.app-category.role-playing-games") == .game)
        #expect(GameModeDetector.evaluate(lowPowerMode: false, classification: .game))
    }

    @Test("A non-game category classifies as non-game and does not pause")
    func nonGameCategoryIsNotGame() {
        #expect(GameModeDetector.classification(forCategory: "public.app-category.productivity") == .nonGame)
        #expect(!GameModeDetector.evaluate(lowPowerMode: false, classification: .nonGame))
    }

    @Test("A missing / unreadable category is unknown and fails open")
    func unknownCategoryFailsOpen() {
        #expect(GameModeDetector.classification(forCategory: nil) == .unknown)
        #expect(!GameModeDetector.evaluate(lowPowerMode: false, classification: .unknown))
    }

    @Test("Only the official games categories match — bare 'games' or near-misses do not")
    func categoryAllowlistIsStrict() {
        #expect(GameModeDetector.isGameCategory("public.app-category.games"))
        #expect(GameModeDetector.isGameCategory("public.app-category.puzzle-games"))
        #expect(!GameModeDetector.isGameCategory("games"))
        #expect(!GameModeDetector.isGameCategory("public.app-category.productivity"))
        #expect(!GameModeDetector.isGameCategory("public.app-category.gamesomething"))
    }

    @Test("Install path is no longer a game signal")
    func installPathIsNotAGameSignal() {
        let steamPlist = URL(fileURLWithPath:
            "/Users/me/Library/Application Support/Steam/steamapps/common/Hades/Hades.app/Contents/Info.plist")
        #expect(GameModeDetector.readClassification(infoPlistAt: steamPlist) == .unknown)
    }

    @Test("A non-existent Info.plist reads as unknown, never throwing")
    func missingPlistIsUnknown() {
        let missing = URL(fileURLWithPath: "/nonexistent/Path.app/Contents/Info.plist")
        #expect(GameModeDetector.readCategory(infoPlistAt: missing) == nil)
        #expect(GameModeDetector.readClassification(infoPlistAt: missing) == .unknown)
    }

    @Test("Low Power Mode forces active regardless of classification")
    func lowPowerModeForcesActive() {
        #expect(GameModeDetector.evaluate(lowPowerMode: true, classification: .unknown))
        #expect(GameModeDetector.evaluate(lowPowerMode: true, classification: .nonGame))
    }

    @Test("First sight fails open, then the background read fills the cache")
    @MainActor
    func firstSightFailsOpenThenCacheFills() async throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("W3GameModeDetector-\(UUID().uuidString).app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["LSApplicationCategoryType": "public.app-category.games"],
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let detector = GameModeDetector()
        #expect(detector.classification(forBundleAt: bundle) == .unknown)
        await detector.awaitPendingClassifications()
        #expect(detector.classification(forBundleAt: bundle) == .game)
    }
}
