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
/// paths the current frame samples.
struct WPEMetalTextureCacheLRU: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let bytes: Int
        let lastAccess: Int
    }

    let budgetBytes: Int
    private(set) var totalBytes = 0
    private(set) var entries: [String: Entry] = [:]
    private var clock = 0

    init(budgetBytes: Int) {
        self.budgetBytes = max(0, budgetBytes)
    }

    mutating func admit(_ key: String, bytes: Int) {
        guard bytes > 0 else {
            remove(key)
            return
        }
        clock += 1
        if let existing = entries[key] {
            totalBytes -= existing.bytes
        }
        entries[key] = Entry(bytes: bytes, lastAccess: clock)
        totalBytes += bytes
    }

    mutating func touch(_ key: String) {
        guard let entry = entries[key] else { return }
        clock += 1
        entries[key] = Entry(bytes: entry.bytes, lastAccess: clock)
    }

    mutating func remove(_ key: String) {
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.bytes
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalBytes = 0
        clock = 0
    }

    /// Evict least-recently-used entries until within budget, never touching a
    /// `protected` (active this frame) path — so an over-budget frame keeps every
    /// active texture resident rather than evicting one it is about to sample.
    @discardableResult
    mutating func evictOverBudget(protecting protected: Set<String>) -> [String] {
        var evicted: [String] = []
        while totalBytes > budgetBytes,
              let victim = entries
                .filter({ !protected.contains($0.key) })
                .min(by: { lhs, rhs in
                    lhs.value.lastAccess != rhs.value.lastAccess
                        ? lhs.value.lastAccess < rhs.value.lastAccess
                        : lhs.key < rhs.key
                })?.key {
            remove(victim)
            evicted.append(victim)
        }
        return evicted
    }
}
#endif
