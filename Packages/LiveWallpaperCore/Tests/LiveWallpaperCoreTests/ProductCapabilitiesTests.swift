import Foundation
import SwiftUI
import Testing
@testable import LiveWallpaperCore

/// Verifies the standalone Core package's SKU capability surface.
@Suite("ProductCapabilities (Core SPM)")
struct ProductCapabilitiesTests {

    @Test("Unconfigured capabilities and environment defaults fail closed")
    func unconfiguredCatalogFailsClosed() {
        let capabilities = ProductCapabilities.unconfigured
        let forged = ProductCapabilities(
            sku: .unconfigured,
            enabledFeatures: Set(ProductFeature.allCases)
        )
        let workshopAttempt = capabilities.withWorkshopOnline()
        let developerToolsAttempt = capabilities.withLocalDeveloperTools()
        let catalog = FeatureCatalog.unconfigured
        let environmentCatalog = EnvironmentValues().featureCatalog

        #expect(capabilities.sku == .unconfigured)
        #expect(capabilities.enabledFeatures.isEmpty)
        #expect(capabilities.selectableWallpaperTypes.isEmpty)
        #expect(capabilities.selectableWallpaperModes.isEmpty)
        #expect(forged.enabledFeatures.isEmpty)
        #expect(workshopAttempt.enabledFeatures.isEmpty)
        #expect(developerToolsAttempt.enabledFeatures.isEmpty)
        #expect(ProductCapabilities.lite.withWorkshopOnline() == .lite)
        #expect(ProductCapabilities.lite.withLocalDeveloperTools() == .lite)
        #expect(ProductFeature.allCases.allSatisfy { !catalog.isEnabled($0) })
        #expect(environmentCatalog == .unconfigured)
    }

    @Test("Lite catalog renders video + html + monitor")
    func liteCatalogWallpaperTypes() {
        let catalog = ProductCapabilities.lite
        #expect(catalog.sku == .lite)
        #expect(catalog.selectableWallpaperTypes == [.video, .html, .monitor])
        #expect(catalog.canRender(.video))
        #expect(catalog.canRender(.html))
        #expect(catalog.canRender(.monitor))
        #expect(!catalog.canRender(.metalShader))
        #expect(!catalog.canRender(.scene))
    }

    @Test("monitorWallpaper — AI-agent modules included — is in both SKUs")
    func monitorWallpaperIsInBothSKUs() {
        #expect(ProductCapabilities.lite.enabledFeatures.contains(.monitorWallpaper))
        #expect(ProductCapabilities.pro.enabledFeatures.contains(.monitorWallpaper))
    }

    @Test("Pro catalog renders every wallpaper type")
    func proCatalogWallpaperTypes() {
        let catalog = ProductCapabilities.pro
        #expect(catalog.sku == .pro)
        #expect(Set(catalog.selectableWallpaperTypes) == Set(WallpaperType.allCases))
    }

    @Test("Shipping catalogs exclude local Developer Tools")
    func shippingCatalogsExcludeDeveloperTools() {
        #expect(!ProductCapabilities.lite.enabledFeatures.contains(.developerTools))
        #expect(!ProductCapabilities.pro.enabledFeatures.contains(.developerTools))
        #expect(!ProductCapabilities.pro.withWorkshopOnline().enabledFeatures.contains(.developerTools))
    }

    @Test("Local Developer Tools can only be layered onto Pro")
    func localDeveloperToolsAreProOnly() {
        let localPro = ProductCapabilities.pro.withLocalDeveloperTools()

        #expect(localPro.sku == .pro)
        #expect(localPro.enabledFeatures.contains(.developerTools))
        #expect(!ProductCapabilities.lite.withLocalDeveloperTools().enabledFeatures.contains(.developerTools))
        #expect(!ProductCapabilities.unconfigured.withLocalDeveloperTools().enabledFeatures.contains(.developerTools))
    }

    @Test("Lite catalog exposes playlist and schedule automation modes")
    func liteCatalogWallpaperModes() {
        #expect(ProductCapabilities.lite.selectableWallpaperModes == [.playlist, .schedule])
    }

    @Test("Pro catalog keeps every automation mode")
    func proCatalogWallpaperModes() {
        #expect(Set(ProductCapabilities.pro.selectableWallpaperModes) == Set(WallpaperMode.allCases))
    }

    @Test("Legacy `single` raw value decodes to .playlist")
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
        #expect(lite.isEnabled(.monitorWallpaper))
        #expect(!lite.isEnabled(.scene))
        #expect(!lite.isEnabled(.metalShader))
        #expect(!lite.isEnabled(.developerTools))

        let pro = FeatureCatalog(capabilities: .pro)
        #expect(pro.isEnabled(.scene))
        #expect(pro.isEnabled(.scheduleAutomation))
        #expect(pro.isEnabled(.systemMonitor))
        #expect(pro.isEnabled(.monitorWallpaper))
        #expect(!pro.isEnabled(.developerTools))

        let localPro = FeatureCatalog(capabilities: .pro.withLocalDeveloperTools())
        #expect(localPro.isEnabled(.developerTools))
    }
}
