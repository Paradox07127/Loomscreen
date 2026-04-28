import Foundation

/// Per-screen behaviour toggles for an HTML wallpaper.
///
/// Defaults are conservative: JavaScript on (most modern wallpapers need it),
/// mouse interaction off (so the wallpaper does not steal Finder clicks),
/// trackers blocked (privacy by default for URL wallpapers), no custom CSS.
struct HTMLConfig: Codable, Equatable {
    /// When `false`, `WKWebView` runs with JS disabled. Useful for static
    /// HTML/SVG art and as a safety hatch for untrusted URLs.
    var allowJavaScript: Bool = true

    /// When `false`, `HTMLWallpaperView.hitTest` returns `nil` so events fall
    /// through to the desktop. When `true`, clicks and scroll events reach
    /// the embedded `WKWebView` so users can interact with the wallpaper.
    var allowMouseInteraction: Bool = false

    /// When `true`, a `WKContentRuleList` blocks common analytics and ad
    /// hosts before they reach the renderer.
    var blockTrackers: Bool = true

    /// Optional user-supplied stylesheet injected at document end.
    /// `nil` (the default) means no extra CSS is injected.
    var customCSS: String? = nil

    static let `default` = HTMLConfig()

    private enum CodingKeys: String, CodingKey {
        case allowJavaScript
        case allowMouseInteraction
        case blockTrackers
        case customCSS
    }

    init(
        allowJavaScript: Bool = true,
        allowMouseInteraction: Bool = false,
        blockTrackers: Bool = true,
        customCSS: String? = nil
    ) {
        self.allowJavaScript = allowJavaScript
        self.allowMouseInteraction = allowMouseInteraction
        self.blockTrackers = blockTrackers
        self.customCSS = customCSS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowJavaScript = try c.decodeIfPresent(Bool.self, forKey: .allowJavaScript) ?? true
        allowMouseInteraction = try c.decodeIfPresent(Bool.self, forKey: .allowMouseInteraction) ?? false
        blockTrackers = try c.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? true
        customCSS = try c.decodeIfPresent(String.self, forKey: .customCSS)
    }
}
