import Foundation

/// Per-screen behavior toggles for an HTML wallpaper.
struct HTMLConfig: Codable, Equatable {
    /// When `false`, `WKWebView` runs with JS disabled. Useful for static
    /// HTML/SVG art and as a safety hatch for untrusted URLs.
    var allowJavaScript: Bool = true

    /// Allows the embedded web view to receive mouse and scroll events.
    var allowMouseInteraction: Bool = false

    /// When `true`, a `WKContentRuleList` blocks common analytics and ad
    /// hosts before they reach the renderer.
    var blockTrackers: Bool = true

    /// Optional user-supplied stylesheet injected at document end.
    /// `nil` (the default) means no extra CSS is injected.
    var customCSS: String? = nil

    /// 静音页面内所有 `<audio>` / `<video>` 元素。与 `applyPerformanceProfile`
    /// 解耦：用户可能希望保留视觉动画但去掉声音。
    var muteAudio: Bool = false

    /// Sets `pageZoom = 1/backingScaleFactor` so `window.innerWidth` reports
    /// physical pixel count instead of logical points. Required for Wallpaper
    /// Engine web wallpapers (designed against Windows DIP) to avoid canvas
    /// misalignment on Retina displays.
    var physicalPixelLayout: Bool = false

    static let `default` = HTMLConfig()

    private enum CodingKeys: String, CodingKey {
        case allowJavaScript
        case allowMouseInteraction
        case blockTrackers
        case customCSS
        case muteAudio
        case physicalPixelLayout
    }

    init(
        allowJavaScript: Bool = true,
        allowMouseInteraction: Bool = false,
        blockTrackers: Bool = true,
        customCSS: String? = nil,
        muteAudio: Bool = false,
        physicalPixelLayout: Bool = false
    ) {
        self.allowJavaScript = allowJavaScript
        self.allowMouseInteraction = allowMouseInteraction
        self.blockTrackers = blockTrackers
        self.customCSS = customCSS
        self.muteAudio = muteAudio
        self.physicalPixelLayout = physicalPixelLayout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowJavaScript = try c.decodeIfPresent(Bool.self, forKey: .allowJavaScript) ?? true
        allowMouseInteraction = try c.decodeIfPresent(Bool.self, forKey: .allowMouseInteraction) ?? false
        blockTrackers = try c.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? true
        customCSS = try c.decodeIfPresent(String.self, forKey: .customCSS)
        muteAudio = try c.decodeIfPresent(Bool.self, forKey: .muteAudio) ?? false
        physicalPixelLayout = try c.decodeIfPresent(Bool.self, forKey: .physicalPixelLayout) ?? false
    }
}
