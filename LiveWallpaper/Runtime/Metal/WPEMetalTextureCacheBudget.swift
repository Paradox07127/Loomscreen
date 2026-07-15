#if !LITE_BUILD
import Foundation

/// Backoff for failed static-texture reloads. Without it a permanently missing
/// file would retry every frame (`ensureActiveStaticTexturesResident`
/// re-schedules while the placeholder is up): exponential 1→2→4→…→30s gaps,
/// giving up after `maxAttempts`; any successful load clears the path's history.
struct WPEStaticTextureReloadThrottle: Equatable, Sendable {
    static let maxAttempts = 5
    private(set) var failureCount = 0
    private(set) var nextAttemptUptime: TimeInterval = 0

    var isExhausted: Bool { failureCount >= Self.maxAttempts }

    func allowsAttempt(at uptime: TimeInterval) -> Bool {
        !isExhausted && uptime >= nextAttemptUptime
    }

    mutating func recordFailure(at uptime: TimeInterval) {
        failureCount += 1
        nextAttemptUptime = uptime + min(pow(2, Double(failureCount - 1)), 30)
    }
}

/// LRU bookkeeping for reloadable static source textures. The renderer owns the
/// actual `MTLTexture` store; this only tracks resident byte estimates and
/// recency so the frame path can evict inactive textures while protecting the
/// paths the current frame samples. Eviction policy: frame-driven sweep that
/// never touches a protected (active this frame) path — see
/// `evictOverBudget(protecting:)`. Bookkeeping itself lives in the shared
/// `WPEMetalLRUByteBudget` core (see `WPEMetalStaticLayerCacheLRU` for the
/// sibling cache with a different — reject-if-oversized — admission policy).
struct WPEMetalTextureCacheLRU: Equatable, Sendable {
    private var core: WPEMetalLRUByteBudget<String>

    var budgetBytes: Int { core.budgetBytes }
    var totalBytes: Int { core.totalBytes }
    var entries: [String: WPEMetalLRUByteBudget<String>.Entry] { core.entries }

    init(budgetBytes: Int) {
        core = WPEMetalLRUByteBudget(budgetBytes: budgetBytes)
    }

    mutating func admit(_ key: String, bytes: Int) {
        guard bytes > 0 else {
            core.remove(key)
            return
        }
        core.record(key, bytes: bytes)
    }

    mutating func touch(_ key: String) {
        core.touch(key)
    }

    mutating func remove(_ key: String) {
        core.remove(key)
    }

    mutating func removeAll() {
        core.removeAll()
    }

    /// Evict least-recently-used entries until within budget, never touching a
    /// `protected` (active this frame) path — so an over-budget frame keeps every
    /// active texture resident rather than evicting one it is about to sample.
    @discardableResult
    mutating func evictOverBudget(protecting protected: Set<String>) -> [String] {
        core.evictOverBudget(protecting: protected)
    }
}
#endif
