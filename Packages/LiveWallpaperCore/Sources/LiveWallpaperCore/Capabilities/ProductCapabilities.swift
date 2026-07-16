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

    /// The system-metrics dashboard wallpaper (`WallpaperType.monitor`).
    /// Available in BOTH Lite and Pro — system monitoring serves the broad
    /// user base. Gates only the wallpaper surface; the AI-agent modules
    /// inside it are gated separately by `.agentFleet`.
    case monitorWallpaper
    /// Pro-only: unlocks the AI-agent sessions + AI-usage modules INSIDE the
    /// monitor wallpaper. Lite users get a full system-metrics dashboard with
    /// no AI rows.
    case agentFleet

    case wpeImport
    case videoEffects
    case weatherReactive

    /// Steam Workshop online surfaces (paste URL → fetch metadata → optional
    /// download via SteamCMD). Added to the Pro catalog by the app target via
    /// `withWorkshopOnline()`; Lite never gets it, so its UI stays unreachable.
    case workshopOnline

    case scheduleAutomation
    case playlists

    case systemMonitor
    case globalShortcuts

    /// Local Pro DEBUG diagnostics only. Shipping SKU catalogs deliberately
    /// exclude this feature; the app target may layer it onto `.pro` while
    /// compiling a local DEBUG build.
    case developerTools

    case lockScreenSnapshots

    /// Apple Aerials are bundled in both Lite and Pro but the disk-scan
    /// pipeline is lazy-loaded (Lite-only consumers must not pay the cost
    /// until the user opens the Aerials surface).
    case appleAerials

    /// Inline preview window inside the inspector. Enabled in BOTH SKUs —
    /// gates only the UI surfacing; `InspectorPreviewController` itself is
    /// constructed unconditionally for Lite and Pro alike.
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

    /// Lite removes only the heavy GPU pipelines (Wallpaper Engine scene
    /// rendering + custom metal shaders) and the developer-tools harness.
    /// Everything else — playlists, schedules, video effects, weather, global
    /// shortcuts, lock-screen snapshots, inspector preview, system monitor —
    /// keeps the same surface area as Pro so the video / HTML / Aerials
    /// experience is feature-complete.
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

    /// Returns a copy of this catalog with `.workshopOnline` inserted into
    /// the feature set. The SKU gate lives in the **main app target**, not in
    /// this SwiftPM package, because Xcode does not propagate
    /// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` from the app target down into
    /// local packages — a `#if LITE_BUILD` here would always be `false`. The
    /// app target is the authority on which SKU it is, and adds the
    /// capability at injection time.
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

    /// Filtered list of automation modes exposed to the WallpaperMode picker.
    /// `.playlist` is the universal default (a single-video setup is just a
    /// one-entry playlist) and is always available. `.schedule` requires
    /// the schedule-automation feature. SKUs with neither still get
    /// `.playlist` so the picker collapses to a single non-selectable
    /// option rather than disappearing entirely.
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
