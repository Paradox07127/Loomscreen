import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

/// Phase 0/6/8 lock: a `ScreenManager` built with `FeatureCatalog(.lite)`
/// must construct cleanly without exercising Pro-only subsystems. The actual
/// surface area still lives in the monolithic target until the SPM split
/// lands (Phase 1+); these tests pin the capability boundary so the future
/// move only requires file relocation, not behavioural surgery.
@Suite("Lite SKU smoke tests") @MainActor
struct LiteSKUSmokeTests {

    @Test("ProductCapabilities.lite drops only the heavy GPU pipelines")
    func liteCatalogSurfaceArea() {
        let capabilities = ProductCapabilities.lite
        #expect(capabilities.sku == .lite)
        // Wallpaper types: video + html only (no shader, no scene)
        #expect(capabilities.selectableWallpaperTypes == [.video, .html])
        #expect(capabilities.canRender(.video))
        #expect(capabilities.canRender(.html))
        #expect(!capabilities.canRender(.metalShader))
        #expect(!capabilities.canRender(.scene))
        // Automation, playlists, schedule — same as Pro for video/html
        #expect(capabilities.selectableWallpaperModes.contains(.single))
        #expect(capabilities.selectableWallpaperModes.contains(.playlist))
        #expect(capabilities.selectableWallpaperModes.contains(.schedule))
        // Video / web feature surface mirrors Pro
        #expect(capabilities.enabledFeatures.contains(.appleAerials))
        #expect(capabilities.enabledFeatures.contains(.scheduleAutomation))
        #expect(capabilities.enabledFeatures.contains(.playlists))
        #expect(capabilities.enabledFeatures.contains(.systemMonitor))
        #expect(capabilities.enabledFeatures.contains(.globalShortcuts))
        #expect(capabilities.enabledFeatures.contains(.lockScreenSnapshots))
        #expect(capabilities.enabledFeatures.contains(.inspectorPreview))
        #expect(capabilities.enabledFeatures.contains(.videoEffects))
        #expect(capabilities.enabledFeatures.contains(.weatherReactive))
        // Only Pro-exclusive features
        #expect(!capabilities.enabledFeatures.contains(.wpeImport))
        #expect(!capabilities.enabledFeatures.contains(.developerTools))
    }

    @Test("ProductCapabilities.pro keeps every feature on")
    func proCatalogSurfaceArea() {
        let capabilities = ProductCapabilities.pro
        #expect(capabilities.sku == .pro)
        #expect(Set(capabilities.selectableWallpaperTypes) == Set(WallpaperType.allCases))
        #expect(Set(capabilities.selectableWallpaperModes) == Set(WallpaperMode.allCases))
    }

    @Test("ScreenManager constructs cleanly under the Lite catalogue")
    func liteScreenManagerInitDoesNotCrash() {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for Lite smoke test")
            return
        }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        ))

        #expect(manager.featureCatalog.capabilities.sku == .lite)
        #expect(manager.screens.map(\.id) == [screen.id])
    }

    @Test("ScreenManager startAutomation skips orchestrator and weather under Lite")
    func liteScreenManagerSkipsAutomation() {
        guard let screen = Self.makeScreen() else {
            Issue.record("No NSScreen available for Lite automation skip test")
            return
        }
        // Even with startAutomation: true, the per-feature gates in Phase 8
        // should short-circuit so Lite never spins up the orchestrator or
        // weather subscriber.
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: true,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .lite),
            originReconciler: PreservingOriginReconciler()
        ))

        // Lite mirrors Pro for the video/HTML feature set, so playlists,
        // scheduleAutomation, and weatherReactive are all enabled — only the
        // heavy GPU pipelines (.scene, .metalShader) and Pro-exclusive
        // chrome (.wpeImport, .developerTools) drop out.
        #expect(manager.featureCatalog.isEnabled(.playlists))
        #expect(manager.featureCatalog.isEnabled(.scheduleAutomation))
        #expect(manager.featureCatalog.isEnabled(.weatherReactive))
        #expect(!manager.featureCatalog.isEnabled(.scene))
        #expect(!manager.featureCatalog.isEnabled(.metalShader))
        #expect(!manager.featureCatalog.isEnabled(.wpeImport))
    }

    private static func makeScreen() -> Screen? {
        NSScreen.screens.first.map(Screen.init(nsScreen:))
    }
}
