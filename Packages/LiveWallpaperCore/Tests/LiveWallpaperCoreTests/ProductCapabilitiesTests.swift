import Foundation
import Testing
@testable import LiveWallpaperCore

/// Phase 1a smoke tests — verify the Core SPM package builds standalone
/// and the public surface for ProductCapabilities matches the main-app
/// version. The main app still uses its own internal copy until Phase 1b
/// switches over; both must agree on the SKU surface area.
@Suite("ProductCapabilities (Core SPM)")
struct ProductCapabilitiesTests {

    @Test("Lite catalog renders video + html only")
    func liteCatalogWallpaperTypes() {
        let catalog = ProductCapabilities.lite
        #expect(catalog.sku == .lite)
        #expect(catalog.selectableWallpaperTypes == [.video, .html])
        #expect(catalog.canRender(.video))
        #expect(catalog.canRender(.html))
        #expect(!catalog.canRender(.metalShader))
        #expect(!catalog.canRender(.scene))
    }

    @Test("Pro catalog renders every wallpaper type")
    func proCatalogWallpaperTypes() {
        let catalog = ProductCapabilities.pro
        #expect(catalog.sku == .pro)
        #expect(Set(catalog.selectableWallpaperTypes) == Set(WallpaperType.allCases))
    }

    @Test("Lite catalog exposes playlist and schedule automation modes")
    func liteCatalogWallpaperModes() {
        #expect(ProductCapabilities.lite.selectableWallpaperModes == [.playlist, .schedule])
    }

    @Test("Pro catalog keeps every automation mode")
    func proCatalogWallpaperModes() {
        #expect(Set(ProductCapabilities.pro.selectableWallpaperModes) == Set(WallpaperMode.allCases))
    }

    @Test("Legacy `single` raw value decodes to .playlist (rollback compat)")
    func legacySingleDecodesToPlaylist() throws {
        let data = try JSONEncoder().encode("single")
        let decoded = try JSONDecoder().decode(WallpaperMode.self, from: data)
        #expect(decoded == .playlist)
    }

    @Test("Known WallpaperMode raw values round-trip")
    func knownModesRoundTrip() throws {
        for mode in WallpaperMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(WallpaperMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    @Test("FeatureCatalog wraps capabilities with a Sendable isEnabled query")
    func featureCatalogQueries() {
        let lite = FeatureCatalog(capabilities: .lite)
        #expect(lite.isEnabled(.video))
        #expect(lite.isEnabled(.html))
        #expect(lite.isEnabled(.appleAerials))
        #expect(lite.isEnabled(.scheduleAutomation))
        #expect(lite.isEnabled(.systemMonitor))
        // Pro-only features (Metal shaders, WPE scene wallpapers, developer
        // tools) must stay off in Lite.
        #expect(!lite.isEnabled(.scene))
        #expect(!lite.isEnabled(.metalShader))
        #expect(!lite.isEnabled(.developerTools))

        let pro = FeatureCatalog(capabilities: .pro)
        #expect(pro.isEnabled(.scene))
        #expect(pro.isEnabled(.scheduleAutomation))
        #expect(pro.isEnabled(.systemMonitor))
    }
}
