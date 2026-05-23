import Testing
@testable import LiveWallpaperCore

@Suite("OnboardingPathPolicy")
struct OnboardingPathPolicyTests {

    @Test("Pro: gallery surfaces only Video + Web")
    func proPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .pro)

        #expect(policy.sku == .pro)
        #expect(policy.galleryActions == [.video, .html])
    }

    @Test("Lite: gallery surfaces only Video + Web (no shader, no WPE, no upsell)")
    func litePolicy() {
        let policy = OnboardingPathPolicy(capabilities: .lite)

        #expect(policy.sku == .lite)
        #expect(policy.galleryActions == [.video, .html])
    }

    @Test("No Aerials/shader/WPE leakage into onboarding policy regardless of SKU")
    func noPromotionalLeakage() {
        for capabilities in [ProductCapabilities.pro, ProductCapabilities.lite] {
            let policy = OnboardingPathPolicy(capabilities: capabilities)
            let dump = policy.galleryActions.map { String(describing: $0).lowercased() }.joined(separator: ",")
            #expect(!dump.contains("aerial"))
            #expect(!dump.contains("shader"))
            #expect(!dump.contains("wpe"))
            #expect(!dump.contains("marketing"))
        }
    }
}
