import Testing
@testable import LiveWallpaperCore

@Suite("OnboardingPathPolicy")
struct OnboardingPathPolicyTests {

    @Test("Unconfigured: no import or gallery action is exposed")
    func unconfiguredPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .unconfigured)

        #expect(policy.sku == .unconfigured)
        #expect(policy.galleryActions.isEmpty)
        #expect(policy.showsWorkshopSetup == false)
    }

    @Test("Pro without the Workshop capability: Import file + Apple Aerials, no setup step")
    func proPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .pro)

        #expect(policy.sku == .pro)
        #expect(policy.galleryActions == [.importFile, .appleAerials])
        #expect(policy.showsWorkshopSetup == false)
    }

    @Test("Pro with the Workshop capability: Import file + Steam Workshop, with setup step")
    func directProPolicy() {
        let policy = OnboardingPathPolicy(capabilities: .pro.withWorkshopOnline())

        #expect(policy.galleryActions == [.importFile, .workshop])
        #expect(policy.showsWorkshopSetup == true)
    }

    @Test("Lite: Import file + Apple Aerials, never Workshop")
    func litePolicy() {
        let policy = OnboardingPathPolicy(capabilities: .lite)

        #expect(policy.sku == .lite)
        #expect(policy.galleryActions == [.importFile, .appleAerials])
        #expect(policy.showsWorkshopSetup == false)
    }
}
