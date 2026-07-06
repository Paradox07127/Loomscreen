import Foundation

/// Per-screen configuration for the `monitor` wallpaper — the bundled
/// first-party system/agent dashboard rendered in a `WKWebView`.
///
/// `agentsEnabled` / `usageEnabled` request the AI-agent modules but are
/// only honoured when the injected `FeatureCatalog` enables `.agentFleet`
/// (a Pro-only capability); the runtime hard-gates them off otherwise, so a
/// Lite user always gets a system-metrics-only dashboard.
///
/// Every field decodes with `decodeIfPresent` + a default so a config
/// written by a newer build (extra keys) or an older one (missing keys)
/// still round-trips — new fields stay backward-compatible.
public struct MonitorWallpaperConfiguration: Codable, Equatable, Sendable {
    public var systemEnabled: Bool
    public var agentsEnabled: Bool
    public var usageEnabled: Bool
    public var showTopProcesses: Bool
    /// Dashboard data-push cadence. The renderer clamps this to a sane
    /// 0.2…2 Hz window regardless of what is persisted here.
    public var refreshHz: Double
    /// When true the wallpaper stops being click-through so the dashboard can
    /// receive clicks (e.g. double-clicking a session to focus its terminal).
    /// Defaults false to match every other wallpaper type.
    public var mouseInteractionEnabled: Bool

    public static let `default` = MonitorWallpaperConfiguration()

    public init(
        systemEnabled: Bool = true,
        agentsEnabled: Bool = false,
        usageEnabled: Bool = false,
        showTopProcesses: Bool = false,
        refreshHz: Double = 1.0,
        mouseInteractionEnabled: Bool = false
    ) {
        self.systemEnabled = systemEnabled
        self.agentsEnabled = agentsEnabled
        self.usageEnabled = usageEnabled
        self.showTopProcesses = showTopProcesses
        self.refreshHz = Self.clampedRefreshHz(refreshHz)
        self.mouseInteractionEnabled = mouseInteractionEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case systemEnabled
        case agentsEnabled
        case usageEnabled
        case showTopProcesses
        case refreshHz
        case mouseInteractionEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemEnabled) ?? true
        agentsEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentsEnabled) ?? false
        usageEnabled = try c.decodeIfPresent(Bool.self, forKey: .usageEnabled) ?? false
        showTopProcesses = try c.decodeIfPresent(Bool.self, forKey: .showTopProcesses) ?? false
        refreshHz = Self.clampedRefreshHz(try c.decodeIfPresent(Double.self, forKey: .refreshHz) ?? 1.0)
        mouseInteractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .mouseInteractionEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(systemEnabled, forKey: .systemEnabled)
        try c.encode(agentsEnabled, forKey: .agentsEnabled)
        try c.encode(usageEnabled, forKey: .usageEnabled)
        try c.encode(showTopProcesses, forKey: .showTopProcesses)
        try c.encode(refreshHz, forKey: .refreshHz)
        try c.encode(mouseInteractionEnabled, forKey: .mouseInteractionEnabled)
    }

    public static func clampedRefreshHz(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.2), 2.0)
    }
}
