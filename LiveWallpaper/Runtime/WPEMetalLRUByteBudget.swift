#if !LITE_BUILD
import Foundation

/// Shared LRU byte-budget bookkeeping (entries/totalBytes/recency clock),
/// factored out of `WPEMetalTextureCacheLRU` and `WPEMetalStaticLayerCacheLRU`
/// — the two used to carry byte-identical `Entry`/`entries`/`totalBytes`/`clock`
/// state and eviction tie-break logic, diverging only in *when* eviction fires
/// (frame-driven protected-set sweep vs reject/evict inline on admit). This
/// type owns only the bookkeeping; each caller keeps its own admission and
/// eviction-triggering policy layered on top.
struct WPEMetalLRUByteBudget<Key: Hashable & Comparable & Sendable>: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let bytes: Int
        let lastAccess: Int
    }

    let budgetBytes: Int
    private(set) var totalBytes = 0
    private(set) var entries: [Key: Entry] = [:]
    private var clock = 0

    init(budgetBytes: Int) {
        self.budgetBytes = max(0, budgetBytes)
    }

    /// Unconditionally records/updates an entry's size and recency. No size
    /// guard, no eviction — callers layer their own admission policy on top.
    mutating func record(_ key: Key, bytes: Int) {
        clock += 1
        if let existing = entries[key] {
            totalBytes -= existing.bytes
        }
        entries[key] = Entry(bytes: bytes, lastAccess: clock)
        totalBytes += bytes
    }

    mutating func touch(_ key: Key) {
        guard let entry = entries[key] else { return }
        clock += 1
        entries[key] = Entry(bytes: entry.bytes, lastAccess: clock)
    }

    mutating func remove(_ key: Key) {
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= existing.bytes
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalBytes = 0
        clock = 0
    }

    /// Least-recently-used key not in `protected`, tie-broken by key for
    /// determinism. Nil when every entry is protected (or there are none).
    func lruVictim(protecting protected: Set<Key>) -> Key? {
        entries
            .filter { !protected.contains($0.key) }
            .min(by: { lhs, rhs in
                lhs.value.lastAccess != rhs.value.lastAccess
                    ? lhs.value.lastAccess < rhs.value.lastAccess
                    : lhs.key < rhs.key
            })?.key
    }

    /// Evict least-recently-used entries until within budget, never touching a
    /// `protected` key — so an over-budget sweep keeps every protected entry
    /// resident rather than evicting one still in use.
    @discardableResult
    mutating func evictOverBudget(protecting protected: Set<Key>) -> [Key] {
        var evicted: [Key] = []
        while totalBytes > budgetBytes, let victim = lruVictim(protecting: protected) {
            remove(victim)
            evicted.append(victim)
        }
        return evicted
    }
}
#endif
