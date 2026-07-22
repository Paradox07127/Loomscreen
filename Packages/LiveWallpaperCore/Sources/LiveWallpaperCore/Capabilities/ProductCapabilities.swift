import Foundation
import SwiftUI

public enum ProductSKU: String, Sendable, Codable {
    /// No product has been selected. This state is intentionally featureless
    /// and is used by dependency defaults so a missed injection fails closed.
    case unconfigured
    case lite
    case pro
}

/// Discrete user-facing capabilities controlled by the SKU. A `WallpaperType`
/// represents *what* an active wallpaper is; `ProductFeature` represents
/// *which* product surfaces or ambient subsystems are wired up to support it.
public enum ProductFeature: String, Sendable, Hashable, Codable, CaseIterable {
    case video
    case html
    case metalShader
    case scene

    /// System-metrics dashboard wallpaper available in both SKUs; AI-agent modules use `.agentFleet` separately.
    case monitorWallpaper
    /// Pro-only AI-agent sessions and usage modules within the monitor wallpaper.
    case agentFleet

    case wpeImport
    case videoEffects
    case weatherReactive

    /// Pro-only Steam Workshop metadata and SteamCMD download surfaces.
    case workshopOnline

    case scheduleAutomation
    case playlists

    case systemMonitor
    case globalShortcuts

    /// Local Pro debug diagnostics excluded from shipping catalogs.
    case developerTools

    case lockScreenSnapshots

    /// Apple Aerials surface, with its disk scan loaded lazily in both SKUs.
    case appleAerials

    /// Inline inspector preview surface available in both SKUs.
    case inspectorPreview
}

public struct ProductCapabilities: Sendable, Equatable {
    public let sku: ProductSKU
    public let enabledFeatures: Set<ProductFeature>

    public init(sku: ProductSKU, enabledFeatures: Set<ProductFeature>) {
        self.sku = sku
        // An unconfigured dependency must never be able to smuggle in a
        // feature through a hand-built capability set.
        self.enabledFeatures = sku == .unconfigured ? [] : enabledFeatures
    }

    /// Fail-closed catalog used until an app/test/preview explicitly chooses
    /// a shipping SKU. It deliberately enables no wallpaper or app feature.
    public static let unconfigured = ProductCapabilities(
        sku: .unconfigured,
        enabledFeatures: []
    )

    /// Lite capability baseline excluding Pro rendering, AI-agent, Workshop, and diagnostic surfaces.
    public static let lite = ProductCapabilities(
        sku: .lite,
        enabledFeatures: [
            .video, .html, .monitorWallpaper,
            .videoEffects, .weatherReactive,
            .scheduleAutomation, .playlists,
            .systemMonitor, .globalShortcuts,
            .lockScreenSnapshots,
            .appleAerials, .inspectorPreview
        ]
    )

    /// Shipping Pro capability baseline. Build-local diagnostics are not a
    /// product feature and must be added explicitly by the app's DEBUG root.
    public static let pro = ProductCapabilities(
        sku: .pro,
        enabledFeatures: [
            .video, .html, .metalShader, .scene,
            .monitorWallpaper, .agentFleet,
            .wpeImport, .videoEffects, .weatherReactive,
            .scheduleAutomation, .playlists,
            .systemMonitor, .globalShortcuts,
            .lockScreenSnapshots, .appleAerials, .inspectorPreview
        ]
    )

    /// Adds Workshop access to Pro only; the app target owns this gate because its compilation conditions do not propagate to SwiftPM dependencies.
    public func withWorkshopOnline() -> ProductCapabilities {
        guard sku == .pro else { return self }
        return ProductCapabilities(sku: sku, enabledFeatures: enabledFeatures.union([.workshopOnline]))
    }

    /// Adds the local diagnostic surface to a Pro catalog. The compile-time
    /// DEBUG boundary belongs to the app target because Xcode target build
    /// conditions are not propagated into this Swift package.
    public func withLocalDeveloperTools() -> ProductCapabilities {
        guard sku == .pro else { return self }
        return ProductCapabilities(sku: sku, enabledFeatures: enabledFeatures.union([.developerTools]))
    }

    public func canRender(_ type: WallpaperType) -> Bool {
        switch type {
        case .video:       return enabledFeatures.contains(.video)
        case .html:        return enabledFeatures.contains(.html)
        case .metalShader: return enabledFeatures.contains(.metalShader)
        case .scene:       return enabledFeatures.contains(.scene)
        case .monitor:     return enabledFeatures.contains(.monitorWallpaper)
        }
    }

    /// Lite UI uses this instead of `WallpaperType.allCases`.
    public var selectableWallpaperTypes: [WallpaperType] {
        WallpaperType.allCases.filter { canRender($0) }
    }

    /// Automation modes enabled by the current catalog; schedule additionally requires `.scheduleAutomation`.
    public var selectableWallpaperModes: [WallpaperMode] {
        guard enabledFeatures.contains(.playlists) else { return [] }
        return WallpaperMode.allCases.filter { mode in
            switch mode {
            case .playlist: return true
            case .schedule: return enabledFeatures.contains(.scheduleAutomation)
            }
        }
    }
}

/// Value-semantic capability catalog distributed through the SwiftUI environment.
public struct FeatureCatalog: Sendable, Equatable {
    public let capabilities: ProductCapabilities

    public init(capabilities: ProductCapabilities) {
        self.capabilities = capabilities
    }

    public func isEnabled(_ feature: ProductFeature) -> Bool {
        capabilities.enabledFeatures.contains(feature)
    }

    public static let unconfigured = FeatureCatalog(capabilities: .unconfigured)
}

private struct FeatureCatalogKey: EnvironmentKey {
    /// Missing SwiftUI injection is a configuration error, not permission to
    /// expose Pro functionality. Shipping roots inject Lite or Pro explicitly.
    static let defaultValue = FeatureCatalog.unconfigured
}

extension EnvironmentValues {
    public var featureCatalog: FeatureCatalog {
        get { self[FeatureCatalogKey.self] }
        set { self[FeatureCatalogKey.self] = newValue }
    }
}
