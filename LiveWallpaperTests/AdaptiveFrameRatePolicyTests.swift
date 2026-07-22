import Testing
@testable import LiveWallpaper

@Suite("Adaptive frame-rate policy")
struct AdaptiveFrameRatePolicyTests {
    private func occlusion(_ fraction: Double, throttled: Bool = false) -> Bool {
        AdaptiveFrameRatePolicy.shouldThrottleForOcclusion(
            occlusionFraction: fraction,
            currentlyThrottled: throttled
        )
    }

    private func combined(
        enabled: Bool = true,
        occlusionThrottled: Bool = false,
        onBattery: Bool = false,
        pausesOnBattery: Bool = false
    ) -> Bool {
        AdaptiveFrameRatePolicy.shouldThrottle(
            enabled: enabled,
            occlusionThrottled: occlusionThrottled,
            onBattery: onBattery,
            pausesOnBattery: pausesOnBattery
        )
    }

    @Test("Disabled never throttles")
    func disabledNeverThrottles() {
        #expect(combined(enabled: false, occlusionThrottled: true) == false)
        #expect(combined(enabled: false, onBattery: true) == false)
    }

    @Test("Occlusion crosses the enter threshold")
    func occlusionEnter() {
        #expect(occlusion(0.49) == false)
        #expect(occlusion(0.5) == true)
    }

    @Test("Hysteresis keeps throttling between exit and enter")
    func hysteresisHoldsInBand() {
        #expect(occlusion(0.45, throttled: true) == true)
        #expect(occlusion(0.39, throttled: true) == false)
        #expect(occlusion(0.45, throttled: false) == false)
    }

    @Test("Battery throttles only when playback is kept on battery")
    func batteryThrottle() {
        #expect(combined(onBattery: true, pausesOnBattery: false) == true)
        #expect(combined(onBattery: true, pausesOnBattery: true) == false)
    }

    @Test("Battery throttle never seeds the occlusion hysteresis latch")
    func batteryDoesNotSeedOcclusionLatch() {
        #expect(combined(occlusionThrottled: occlusion(0.45), onBattery: true) == true)
        #expect(occlusion(0.45, throttled: false) == false)
        #expect(combined(occlusionThrottled: occlusion(0.45), onBattery: false) == false)
    }
}
