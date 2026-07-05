#if !LITE_BUILD
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("WPE Metal texture cache budget")
struct WPEMetalTextureCacheBudgetTests {
    @Test("Memory tiers map physical RAM to the expected bucket")
    func memoryTierMapping() {
        let gib: UInt64 = 1_073_741_824
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 8 * gib) == .constrained)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 12 * gib) == .standard)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 16 * gib) == .standard)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 18 * gib) == .standard)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 24 * gib) == .expansive)
        #expect(WPEMemoryTier.tier(forPhysicalMemoryBytes: 64 * gib) == .expansive)
    }

    @Test("Memory tiers carry the intended renderer defaults")
    func memoryTierDefaults() {
        #expect(WPEMemoryTier.constrained.defaultTextureCacheBudgetBytes == 256 * 1_048_576)
        #expect(WPEMemoryTier.standard.defaultTextureCacheBudgetBytes == 512 * 1_048_576)
        #expect(WPEMemoryTier.expansive.defaultTextureCacheBudgetBytes == nil)
        #expect(WPEMemoryTier.constrained.lazyAnimationRawByteThreshold == 100_000_000)
        #expect(WPEMemoryTier.standard.lazyAnimationRawByteThreshold == 200_000_000)
        #expect(WPEMemoryTier.expansive.lazyAnimationRawByteThreshold == 200_000_000)
    }

    @Test("Budget resolution: unset follows the tier, manual value always wins")
    func budgetResolutionPrecedence() {
        for tier in [WPEMemoryTier.constrained, .standard, .expansive] {
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: nil, tier: tier)
                == tier.defaultTextureCacheBudgetBytes)
            // Explicit 0 / negative / non-numeric ⇒ manual opt-out to unbounded.
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: 0, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: -5, tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: "junk", tier: tier) == nil)
            #expect(WPEMetalSceneRenderer.resolvedTextureCacheBudgetBytes(manualValue: 64, tier: tier)
                == 64 * 1_048_576)
        }
    }

    @Test("Budget defaults-key round-trip matches the resolution rules")
    func textureCacheBudgetDefaultsRoundTrip() {
        let defaults = UserDefaults.standard
        let key = WPEMetalSceneRenderer.textureCacheBudgetMiBDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.removeObject(forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes
            == WPEMemoryTier.current.defaultTextureCacheBudgetBytes)
        defaults.set(0, forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == nil)
        defaults.set(64, forKey: key)
        #expect(WPEMetalSceneRenderer.textureCacheBudgetBytes == 64 * 1_048_576)
    }

    @Test("Reload throttle backs off exponentially and gives up at the cap")
    func reloadThrottleBackoff() {
        var throttle = WPEStaticTextureReloadThrottle()
        #expect(throttle.allowsAttempt(at: 0))

        throttle.recordFailure(at: 100)
        #expect(!throttle.allowsAttempt(at: 100.5))
        #expect(throttle.allowsAttempt(at: 101))          // +1s
        throttle.recordFailure(at: 101)
        #expect(!throttle.allowsAttempt(at: 102.5))
        #expect(throttle.allowsAttempt(at: 103))          // +2s
        throttle.recordFailure(at: 103)
        #expect(throttle.allowsAttempt(at: 107))          // +4s
        throttle.recordFailure(at: 107)
        #expect(throttle.allowsAttempt(at: 115))          // +8s
        #expect(!throttle.isExhausted)

        throttle.recordFailure(at: 115)
        #expect(throttle.isExhausted)
        #expect(!throttle.allowsAttempt(at: 10_000))      // capped out forever
        #expect(throttle.failureCount == WPEStaticTextureReloadThrottle.maxAttempts)
    }

    @Test("Resident-byte estimate covers the mip chain when one exists")
    func residentBytesCountMipChain() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func makeTexture(mipmapped: Bool) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 64,
                height: 64,
                mipmapped: mipmapped
            )
            descriptor.usage = [.shaderRead]
            return try #require(device.makeTexture(descriptor: descriptor))
        }
        let flat = try makeTexture(mipmapped: false)
        let mipped = try makeTexture(mipmapped: true)
        let base = 64 * 64 * 4
        #expect(WPEMetalSceneRenderer.textureResidentBytes(for: flat) == base)
        #expect(WPEMetalSceneRenderer.textureResidentBytes(for: mipped) == base * 4 / 3)
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
