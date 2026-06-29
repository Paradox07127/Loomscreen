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
        // Already throttled, coverage drifts into the dead band: stays on.
        #expect(occlusion(0.45, throttled: true) == true)
        // Drops below the exit threshold: releases.
        #expect(occlusion(0.39, throttled: true) == false)
        // Not yet throttled, same dead-band value: must NOT start (no flap).
        #expect(occlusion(0.45, throttled: false) == false)
    }

    @Test("Battery throttles only when playback is kept on battery")
    func batteryThrottle() {
        #expect(combined(onBattery: true, pausesOnBattery: false) == true)
        // pauseOnBattery already suspends, so the throttle rule defers.
        #expect(combined(onBattery: true, pausesOnBattery: true) == false)
    }

    @Test("Battery throttle never seeds the occlusion hysteresis latch")
    func batteryDoesNotSeedOcclusionLatch() {
        // On battery at 45% coverage the *combined* gate throttles…
        #expect(combined(occlusionThrottled: occlusion(0.45), onBattery: true) == true)
        // …but the occlusion arm (which feeds the latch) stays false, so once
        // unplugged at 45% it releases instead of sticking on the 0.4 exit edge.
        #expect(occlusion(0.45, throttled: false) == false)
        #expect(combined(occlusionThrottled: occlusion(0.45), onBattery: false) == false)
    }
}
