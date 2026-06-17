import Foundation
import Testing
@testable import LiveWallpaper

/// Pure-classifier coverage for `GameModeDetector`. The load-bearing contract:
/// a real (Steam-launched) game pauses the wallpaper, while a maximised
/// non-game window (Safari/Finder) does not — proven without a live game by
/// driving the injectable `evaluate` / `isGame` seam.
@Suite("GameModeDetector classification")
struct GameModeDetectorTests {

    private func app(
        bundleID: String? = nil,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        category: String? = nil
    ) -> GameModeDetector.FrontmostApp {
        GameModeDetector.FrontmostApp(
            bundleID: bundleID,
            bundlePath: bundlePath,
            executablePath: executablePath,
            category: category
        )
    }

    // MARK: - The fix: Steam-launched game executables

    @Test("A Steam game executable (no category, non-launcher bundle) is a game")
    func steamGameExecutableIsGame() {
        let hades = app(
            bundleID: "com.supergiant.hades",
            bundlePath: "/Users/me/Library/Application Support/Steam/steamapps/common/Hades/Hades.app",
            executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/Hades/Hades.app/Contents/MacOS/Hades",
            category: nil
        )
        #expect(GameModeDetector.isGame(hades))
    }

    @Test("Custom SteamLibrary path is matched case-insensitively")
    func customSteamLibraryIsGame() {
        let game = app(executablePath: "/Volumes/Games/SteamLibrary/SteamApps/Common/Celeste/Celeste.app/Contents/MacOS/Celeste")
        #expect(GameModeDetector.isGame(game))
    }

    @Test("Epic / Battle.net / GOG install roots are games")
    func otherLauncherInstallRootsAreGames() {
        #expect(GameModeDetector.isGameInstallPath("/Users/me/Epic Games/Fortnite/Game.app"))
        #expect(GameModeDetector.isGameInstallPath("/Applications/Battle.net/World of Warcraft/wow.app"))
        #expect(GameModeDetector.isGameInstallPath("/Users/me/GOG Games/Witcher/witcher.app"))
    }

    // MARK: - The false-positive guard: maximised non-game windows

    @Test("A maximised Safari window is not a game")
    func maximisedSafariIsNotGame() {
        let safari = app(
            bundleID: "com.apple.Safari",
            bundlePath: "/Applications/Safari.app",
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            category: "public.app-category.productivity"
        )
        #expect(!GameModeDetector.isGame(safari))
    }

    @Test("Finder under /System is not a game")
    func finderIsNotGame() {
        let finder = app(
            bundleID: "com.apple.finder",
            bundlePath: "/System/Library/CoreServices/Finder.app",
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        )
        #expect(!GameModeDetector.isGame(finder))
    }

    // MARK: - Existing signals still hold

    @Test("Storefront launcher bundle prefix is a game (launcher window in front)")
    func launcherPrefixIsGame() {
        #expect(GameModeDetector.isGame(app(bundleID: "com.valvesoftware.steam.helper", bundlePath: "/Applications/Steam.app")))
        #expect(GameModeDetector.isGame(app(bundleID: "com.epicgames.launcher", bundlePath: "/Applications/Epic Games Launcher.app")))
    }

    @Test("A declared game category is a game even outside install roots")
    func declaredGameCategoryIsGame() {
        let storeGame = app(
            bundleID: "com.example.indie",
            bundlePath: "/Applications/Indie.app",
            executablePath: "/Applications/Indie.app/Contents/MacOS/Indie",
            category: "public.app-category.action-games"
        )
        #expect(GameModeDetector.isGame(storeGame))
    }

    @Test("isGameCategory matches the games variants only")
    func gameCategoryStringMatching() {
        #expect(GameModeDetector.isGameCategory("public.app-category.games"))
        #expect(GameModeDetector.isGameCategory("public.app-category.role-playing-games"))
        #expect(!GameModeDetector.isGameCategory("public.app-category.productivity"))
        #expect(!GameModeDetector.isGameCategory("games"))           // missing prefix
        #expect(!GameModeDetector.isGameCategory(nil))
    }

    // MARK: - evaluate() top-level branches

    @Test("Low Power Mode forces active regardless of frontmost app")
    func lowPowerModeForcesActive() {
        #expect(GameModeDetector.evaluate(lowPowerMode: true, frontmost: nil))
        #expect(GameModeDetector.evaluate(lowPowerMode: true, frontmost: app(bundleID: "com.apple.Safari")))
    }

    @Test("No frontmost app and no Low Power Mode is inactive")
    func noFrontmostIsInactive() {
        #expect(!GameModeDetector.evaluate(lowPowerMode: false, frontmost: nil))
    }

    @Test("evaluate routes a non-game frontmost to false and a game to true")
    func evaluateRoutesThroughClassifier() {
        let safari = app(bundleID: "com.apple.Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
        let game = app(executablePath: "/Users/me/Library/Application Support/Steam/steamapps/common/Hollow Knight/hollow_knight.app/Contents/MacOS/hollow_knight")
        #expect(!GameModeDetector.evaluate(lowPowerMode: false, frontmost: safari))
        #expect(GameModeDetector.evaluate(lowPowerMode: false, frontmost: game))
    }
}
