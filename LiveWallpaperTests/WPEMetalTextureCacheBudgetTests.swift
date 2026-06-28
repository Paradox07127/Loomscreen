#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal texture cache budget")
struct WPEMetalTextureCacheBudgetTests {
    @Test("Texture cache budget defaults disabled")
    func textureCacheBudgetDefaultsDisabled() {
        let defaults = UserDefaults.standard
        let key = WPEMetalSceneRenderer.textureCacheBudgetMiBDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == nil)
        defaults.set(0, forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == nil)
        defaults.set(64, forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == 64 * 1_048_576)
    }

    @Test("LRU evicts least-recently-used inactive entries")
    func lruEvictsOldestInactive() {
        var lru = WPEMetalTextureCacheLRU(budgetBytes: 100)
        lru.admit("a", bytes: 40)
        lru.admit("b", bytes: 40)
        lru.touch("a")          // a now newer than b
        lru.admit("c", bytes: 40) // over budget (120 > 100)

        let evicted = lru.evictOverBudget(protecting: [])

        #expect(evicted == ["b"])
        #expect(lru.entries["a"] != nil)
        #expect(lru.entries["b"] == nil)
        #expect(lru.entries["c"] != nil)
        #expect(lru.totalBytes == 80)
    }

    @Test("LRU never evicts protected active paths")
    func lruProtectsActivePaths() {
        var lru = WPEMetalTextureCacheLRU(budgetBytes: 100)
        lru.admit("hidden-old", bytes: 60)
        lru.admit("visible-new", bytes: 60)

        let evicted = lru.evictOverBudget(protecting: ["visible-new"])

        #expect(evicted == ["hidden-old"])
        #expect(lru.entries["visible-new"] != nil)
        #expect(lru.totalBytes == 60)
    }

    @Test("LRU stays over budget rather than evict an active entry")
    func lruKeepsAllProtected() {
        var lru = WPEMetalTextureCacheLRU(budgetBytes: 50)
        lru.admit("visible", bytes: 80)

        let evicted = lru.evictOverBudget(protecting: ["visible"])

        #expect(evicted.isEmpty)
        #expect(lru.entries["visible"] != nil)
        #expect(lru.totalBytes == 80)
    }
}
#endif
