import Foundation
import SwiftUI

public enum ProductSKU: String, Sendable, Codable {
    case lite
    case pro
}

/// Discrete user-facing capabilities controlled by the SKU. A `WallpaperType`
/// represents *what* an active wallpaper is; `ProductFeature` represents
/// *which* product surfaces or ambient subsystems are wired up to support it.
public enum ProductFeature: String, Sendable, Hashable, Codable {
    case video
    case html
    case metalShader
    case scene

    case wpeImport
    case videoEffects
    case weatherReactive

    case scheduleAutomation
    case playlists

    case systemMonitor
    case globalShortcuts
    case developerTools

    case lockScreenSnapshots

    /// Apple Aerials are bundled in both Lite and Pro but the disk-scan
    /// pipeline is lazy-loaded (Lite-only consumers must not pay the cost
    /// until the user opens the Aerials surface).
    case appleAerials

    /// Inline preview window inside the inspector. Pro-only — Lite drops the
    /// `InspectorPreviewController` initialization entirely.
    case inspectorPreview
}

public struct ProductCapabilities: Sendable, Equatable {
    public let sku: ProductSKU
    public let enabledFeatures: Set<ProductFeature>

    public init(sku: ProductSKU, enabledFeatures: Set<ProductFeature>) {
        self.sku = sku
        self.enabledFeatures = enabledFeatures
    }

    /// Lite removes only the heavy GPU pipelines (Wallpaper Engine scene
    /// rendering + custom metal shaders) and the developer-tools harness.
    /// Everything else — playlists, schedules, video effects, weather, global
    /// shortcuts, lock-screen snapshots, inspector preview, system monitor —
    /// keeps the same surface area as Pro so the video / HTML / Aerials
    /// experience is feature-complete.
    public static let lite = ProductCapabilities(
        sku: .lite,
        enabledFeatures: [
            .video, .html,
            .videoEffects, .weatherReactive,
            .scheduleAutomation, .playlists,
            .systemMonitor, .globalShortcuts,
            .lockScreenSnapshots,
            .appleAerials, .inspectorPreview
        ]
    )

    public static let pro = ProductCapabilities(
        sku: .pro,
        enabledFeatures: [
            .video, .html, .metalShader, .scene,
            .wpeImport, .videoEffects, .weatherReactive,
            .scheduleAutomation, .playlists,
            .systemMonitor, .globalShortcuts, .developerTools,
            .lockScreenSnapshots, .appleAerials, .inspectorPreview
        ]
    )

    /// Whether the runtime is permitted to ever render a wallpaper of `type`.
    /// Used by `WallpaperRuntimeFactory` to short-circuit unsupported types
    /// without instantiating a session.
    public func canRender(_ type: WallpaperType) -> Bool {
        switch type {
        case .video:       return enabledFeatures.contains(.video)
        case .html:        return enabledFeatures.contains(.html)
        case .metalShader: return enabledFeatures.contains(.metalShader)
        case .scene:       return enabledFeatures.contains(.scene)
        }
    }

    /// Filtered list of types to expose in the picker. Lite UI uses this
    /// directly instead of `WallpaperType.allCases`.
    public var selectableWallpaperTypes: [WallpaperType] {
        WallpaperType.allCases.filter { canRender($0) }
    }

    /// Filtered list of automation modes exposed to the WallpaperMode picker.
    /// `.single` is always available; `.playlist` and `.schedule` require
    /// the corresponding features. Lite collapses the picker to a single
    /// option when both automation features are disabled.
    public var selectableWallpaperModes: [WallpaperMode] {
        WallpaperMode.allCases.filter { mode in
            switch mode {
            case .single:   return true
            case .playlist: return enabledFeatures.contains(.playlists)
            case .schedule: return enabledFeatures.contains(.scheduleAutomation)
            }
        }
    }
}

/// Lightweight wrapper distributed through SwiftUI environment so any view
/// can short-circuit Pro-only branches with a single `catalog.isEnabled(…)`
/// check. Held by value (Sendable struct) so it can cross actor boundaries.
public struct FeatureCatalog: Sendable, Equatable {
    public let capabilities: ProductCapabilities

    public init(capabilities: ProductCapabilities) {
        self.capabilities = capabilities
    }

    public func isEnabled(_ feature: ProductFeature) -> Bool {
        capabilities.enabledFeatures.contains(feature)
    }
}

private struct FeatureCatalogKey: EnvironmentKey {
    /// Default to the full Pro catalog so existing views that have not yet
    /// been migrated to read the environment value preserve current
    /// behaviour. Phase 6 Lite shell injects `.lite` at the App level.
    static let defaultValue = FeatureCatalog(capabilities: .pro)
}

extension EnvironmentValues {
    public var featureCatalog: FeatureCatalog {
        get { self[FeatureCatalogKey.self] }
        set { self[FeatureCatalogKey.self] = newValue }
    }
}
