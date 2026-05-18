import Foundation

/// Per-screen behavior toggles for an HTML wallpaper.
public struct HTMLConfig: Codable, Equatable, Sendable {
    /// When `false`, `WKWebView` runs with JS disabled. Useful for static
    /// HTML/SVG art and as a safety hatch for untrusted URLs.
    public var allowJavaScript: Bool = true

    /// Allows the embedded web view to receive mouse and scroll events.
    public var allowMouseInteraction: Bool = false

    /// When `true`, a `WKContentRuleList` blocks common analytics and ad
    /// hosts before they reach the renderer.
    public var blockTrackers: Bool = true

    /// Optional user-supplied stylesheet injected at document end.
    /// `nil` (the default) means no extra CSS is injected.
    public var customCSS: String? = nil

    /// Hard mute on all media — separate from `audioVolume` so unmute can
    /// restore the previous level instead of jumping to full volume.
    public var muteAudio: Bool = false

    /// HTML media output level (0.0–1.0). Applied via injected JS to every
    /// `<audio>` / `<video>` element AND through a master `GainNode` patched
    /// onto `BaseAudioContext.destination` so Web Audio API graphs are
    /// covered too. WKWebView has no native volume API so this is the only
    /// way to get a real slider for HTML wallpapers.
    public var audioVolume: Double = 1.0

    /// Auto-reload interval for the embedded page. `0` (the default) disables
    /// the timer. Stored as seconds because the UI exposes both presets
    /// (1 min / 5 min / 30 min / 1 h / 6 h) and an arbitrary "every N
    /// minutes" override.
    public var refreshIntervalSeconds: Int = 0

    /// CSS `transform: scale()` factor applied to `<body>`. `1.0` is identity.
    public var transformScale: Double = 1.0

    /// CSS `transform: translate(Xpx, Ypx)` X offset in CSS pixels.
    public var transformTranslateX: Double = 0

    /// CSS `transform: translate(Xpx, Ypx)` Y offset in CSS pixels.
    public var transformTranslateY: Double = 0

    /// CSS `transform: rotate(Rdeg)` rotation in degrees. Positive = clockwise.
    public var transformRotationDegrees: Double = 0

    /// Sets `pageZoom = 1/backingScaleFactor` so `window.innerWidth` reports
    /// physical pixel count instead of logical points. Required for Wallpaper
    /// Engine web wallpapers (designed against Windows DIP) to avoid canvas
    /// misalignment on Retina displays.
    public var physicalPixelLayout: Bool = false

    /// When `true`, runs `WKWebView` with `WKWebsiteDataStore.nonPersistent()`
    /// so cookies / cache / localStorage do not persist across sessions —
    /// useful for kiosk-style wallpapers and untrusted URL sources. Toggling
    /// this only takes effect on the next session rebuild because WebKit
    /// cannot swap its data store after init.
    public var useEphemeralStorage: Bool = false

    /// Maximum auto-retry attempts after navigation failures. Exponential
    /// backoff: 1s, 2s, 4s ... up to `maxRetries`. After the budget is
    /// exhausted the runtime surfaces the error in the screen-detail banner.
    public var maxRetries: Int = 3

    public static let `default` = HTMLConfig()

    /// Bounds for `audioVolume`. Defined on the type so UI sliders and
    /// migration both read the same source.
    public static let minAudioVolume: Double = 0
    public static let maxAudioVolume: Double = 1

    /// Bounds for `transformScale`. Keep tight enough to avoid runaway
    /// fractional rendering — anything below 0.1 makes the page invisible,
    /// anything above 3 produces severe content clipping.
    public static let minTransformScale: Double = 0.1
    public static let maxTransformScale: Double = 3.0

    /// Bounds for translate in CSS pixels. The UI clamps to ±10000 px so a
    /// stray scroll-wheel gesture in a Stepper can't translate the body
    /// off into infinity.
    public static let maxTransformTranslate: Double = 10000

    /// Bounds for the refresh timer. Anything below 5s is rejected because
    /// `WKWebView.reload()` itself takes ~50–200ms and the page rarely has
    /// time to render before being torn down again.
    public static let minRefreshIntervalSeconds: Int = 0
    public static let maxRefreshIntervalSeconds: Int = 24 * 60 * 60

    private enum CodingKeys: String, CodingKey {
        case allowJavaScript
        case allowMouseInteraction
        case blockTrackers
        case customCSS
        case muteAudio
        case audioVolume
        case refreshIntervalSeconds
        case transformScale
        case transformTranslateX
        case transformTranslateY
        case transformRotationDegrees
        case physicalPixelLayout
        case useEphemeralStorage
        case maxRetries
    }

    public init(
        allowJavaScript: Bool = true,
        allowMouseInteraction: Bool = false,
        blockTrackers: Bool = true,
        customCSS: String? = nil,
        muteAudio: Bool = false,
        audioVolume: Double = 1.0,
        refreshIntervalSeconds: Int = 0,
        transformScale: Double = 1.0,
        transformTranslateX: Double = 0,
        transformTranslateY: Double = 0,
        transformRotationDegrees: Double = 0,
        physicalPixelLayout: Bool = false,
        useEphemeralStorage: Bool = false,
        maxRetries: Int = 3
    ) {
        self.allowJavaScript = allowJavaScript
        self.allowMouseInteraction = allowMouseInteraction
        self.blockTrackers = blockTrackers
        self.customCSS = customCSS
        self.muteAudio = muteAudio
        self.audioVolume = Self.clampedAudioVolume(audioVolume)
        self.refreshIntervalSeconds = Self.clampedRefreshInterval(refreshIntervalSeconds)
        self.transformScale = Self.clampedTransformScale(transformScale)
        self.transformTranslateX = Self.clampedTransformTranslate(transformTranslateX)
        self.transformTranslateY = Self.clampedTransformTranslate(transformTranslateY)
        self.transformRotationDegrees = Self.clampedTransformRotation(transformRotationDegrees)
        self.physicalPixelLayout = physicalPixelLayout
        self.useEphemeralStorage = useEphemeralStorage
        self.maxRetries = maxRetries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowJavaScript = try c.decodeIfPresent(Bool.self, forKey: .allowJavaScript) ?? true
        allowMouseInteraction = try c.decodeIfPresent(Bool.self, forKey: .allowMouseInteraction) ?? false
        blockTrackers = try c.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? true
        customCSS = try c.decodeIfPresent(String.self, forKey: .customCSS)
        muteAudio = try c.decodeIfPresent(Bool.self, forKey: .muteAudio) ?? false
        let decodedVolume = try c.decodeIfPresent(Double.self, forKey: .audioVolume) ?? 1.0
        audioVolume = Self.clampedAudioVolume(decodedVolume)
        let decodedRefresh = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalSeconds) ?? 0
        refreshIntervalSeconds = Self.clampedRefreshInterval(decodedRefresh)
        let decodedScale = try c.decodeIfPresent(Double.self, forKey: .transformScale) ?? 1.0
        transformScale = Self.clampedTransformScale(decodedScale)
        let decodedTX = try c.decodeIfPresent(Double.self, forKey: .transformTranslateX) ?? 0
        transformTranslateX = Self.clampedTransformTranslate(decodedTX)
        let decodedTY = try c.decodeIfPresent(Double.self, forKey: .transformTranslateY) ?? 0
        transformTranslateY = Self.clampedTransformTranslate(decodedTY)
        let decodedRotation = try c.decodeIfPresent(Double.self, forKey: .transformRotationDegrees) ?? 0
        transformRotationDegrees = Self.clampedTransformRotation(decodedRotation)
        physicalPixelLayout = try c.decodeIfPresent(Bool.self, forKey: .physicalPixelLayout) ?? false
        useEphemeralStorage = try c.decodeIfPresent(Bool.self, forKey: .useEphemeralStorage) ?? false
        let decodedRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 3
        maxRetries = min(max(0, decodedRetries), 10)
    }

    public static func clampedAudioVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, minAudioVolume), maxAudioVolume)
    }

    public static func clampedRefreshInterval(_ value: Int) -> Int {
        if value <= 0 { return 0 }
        return min(max(value, 5), maxRefreshIntervalSeconds)
    }

    public static func clampedTransformScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, minTransformScale), maxTransformScale)
    }

    public static func clampedTransformTranslate(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -maxTransformTranslate), maxTransformTranslate)
    }

    public static func clampedTransformRotation(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        // Normalize to (-360, 360] so the persisted value stays readable.
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped
    }
}
