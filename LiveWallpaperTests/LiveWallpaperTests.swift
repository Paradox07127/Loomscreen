import Testing
import Foundation
import CoreGraphics
@testable import LiveWallpaper

// MARK: - PowerPolicyController Tests

@Suite("PowerPolicyController") @MainActor
struct PowerPolicyControllerTests {

    @Test("Mark and query power pause")
    func powerPause() {
        let controller = PowerPolicyController()
        let screen: CGDirectDisplayID = 42

        #expect(!controller.wasPausedByPower(screen))
        controller.markPausedByPower(screen)
        #expect(controller.wasPausedByPower(screen))
        #expect(!controller.wasPausedByFullScreen(screen))

        controller.markResumedFromPower(screen)
        #expect(!controller.wasPausedByPower(screen))
    }

    @Test("Mark and query full-screen pause")
    func fullScreenPause() {
        let controller = PowerPolicyController()
        let screen: CGDirectDisplayID = 99

        controller.markPausedByFullScreen(screen)
        #expect(controller.wasPausedByFullScreen(screen))
        #expect(!controller.wasPausedByPower(screen))

        controller.markResumedFromFullScreen(screen)
        #expect(!controller.wasPausedByFullScreen(screen))
    }

    @Test("Power and full-screen are independent")
    func independentTracking() {
        let controller = PowerPolicyController()
        let screen: CGDirectDisplayID = 10

        controller.markPausedByPower(screen)
        controller.markPausedByFullScreen(screen)
        #expect(controller.wasPausedByPower(screen))
        #expect(controller.wasPausedByFullScreen(screen))

        controller.markResumedFromPower(screen)
        #expect(!controller.wasPausedByPower(screen))
        #expect(controller.wasPausedByFullScreen(screen))
    }

    @Test("Clear tracking removes both states")
    func clearTracking() {
        let controller = PowerPolicyController()
        let screen: CGDirectDisplayID = 5

        controller.markPausedByPower(screen)
        controller.markPausedByFullScreen(screen)
        controller.clearTracking(for: screen)

        #expect(!controller.wasPausedByPower(screen))
        #expect(!controller.wasPausedByFullScreen(screen))
    }

    @Test("Clean up stale entries removes disconnected screens")
    func cleanUpStaleEntries() {
        let controller = PowerPolicyController()
        let active: CGDirectDisplayID = 1
        let disconnected: CGDirectDisplayID = 2

        controller.markPausedByPower(active)
        controller.markPausedByPower(disconnected)
        controller.markPausedByFullScreen(disconnected)

        controller.cleanUpStaleEntries(currentScreenIDs: [active])

        #expect(controller.wasPausedByPower(active))
        #expect(!controller.wasPausedByPower(disconnected))
        #expect(!controller.wasPausedByFullScreen(disconnected))
    }

    @Test("Multiple screens tracked independently")
    func multipleScreens() {
        let controller = PowerPolicyController()
        let s1: CGDirectDisplayID = 1
        let s2: CGDirectDisplayID = 2

        controller.markPausedByPower(s1)
        controller.markPausedByFullScreen(s2)

        #expect(controller.wasPausedByPower(s1))
        #expect(!controller.wasPausedByFullScreen(s1))
        #expect(!controller.wasPausedByPower(s2))
        #expect(controller.wasPausedByFullScreen(s2))
    }

    @Test("Idempotent mark/resume operations")
    func idempotent() {
        let controller = PowerPolicyController()
        let screen: CGDirectDisplayID = 7

        // Double mark — no crash, still tracked
        controller.markPausedByPower(screen)
        controller.markPausedByPower(screen)
        #expect(controller.wasPausedByPower(screen))

        // Double resume — no crash, still untracked
        controller.markResumedFromPower(screen)
        controller.markResumedFromPower(screen)
        #expect(!controller.wasPausedByPower(screen))
    }
}

// MARK: - FrameRateLimit Tests

@Suite("FrameRateLimit.getEffectiveLimit")
struct FrameRateLimitTests {

    @Test("Unlimited: video below screen refresh → no limit")
    func unlimitedBelowScreen() {
        let result = FrameRateLimit.unlimited.getEffectiveLimit(videoFrameRate: 30, screenRefreshRate: 60)
        #expect(result == 0)
    }

    @Test("Unlimited: video above screen refresh → cap to screen")
    func unlimitedAboveScreen() {
        let result = FrameRateLimit.unlimited.getEffectiveLimit(videoFrameRate: 120, screenRefreshRate: 60)
        #expect(result == 60)
    }

    @Test("Unlimited: zero screen refresh → no limit")
    func unlimitedZeroScreen() {
        let result = FrameRateLimit.unlimited.getEffectiveLimit(videoFrameRate: 60, screenRefreshRate: 0)
        #expect(result == 0)
    }

    @Test("30 FPS limit: normal case")
    func fps30Normal() {
        let result = FrameRateLimit.fps30.getEffectiveLimit(videoFrameRate: 60, screenRefreshRate: 60)
        #expect(result == 30)
    }

    @Test("60 FPS limit: video below limit → no limit needed")
    func fps60BelowVideo() {
        let result = FrameRateLimit.fps60.getEffectiveLimit(videoFrameRate: 30, screenRefreshRate: 60)
        #expect(result == 0)
    }

    @Test("60 FPS limit: screen below limit → cap to screen")
    func fps60ScreenBelow() {
        let result = FrameRateLimit.fps60.getEffectiveLimit(videoFrameRate: 120, screenRefreshRate: 48)
        #expect(result == 48)
    }

    @Test("30 FPS limit: screen below 30 → cap to screen")
    func fps30ScreenBelow() {
        let result = FrameRateLimit.fps30.getEffectiveLimit(videoFrameRate: 60, screenRefreshRate: 24)
        #expect(result == 24)
    }

    @Test("Decoder: valid raw values")
    func decoderValid() throws {
        let data30 = try JSONEncoder().encode(30)
        let decoded30 = try JSONDecoder().decode(FrameRateLimit.self, from: data30)
        #expect(decoded30 == .fps30)

        let data60 = try JSONEncoder().encode(60)
        let decoded60 = try JSONDecoder().decode(FrameRateLimit.self, from: data60)
        #expect(decoded60 == .fps60)

        let data0 = try JSONEncoder().encode(0)
        let decoded0 = try JSONDecoder().decode(FrameRateLimit.self, from: data0)
        #expect(decoded0 == .unlimited)
    }

    @Test("Decoder: invalid raw value defaults to fps60")
    func decoderInvalid() throws {
        let data = try JSONEncoder().encode(999)
        let decoded = try JSONDecoder().decode(FrameRateLimit.self, from: data)
        #expect(decoded == .fps60)
    }
}

// MARK: - ScheduleSlot Tests

@Suite("ScheduleSlot.containsHour")
struct ScheduleSlotTests {

    @Test("Normal range: 6-12 contains 9")
    func normalRangeInside() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        #expect(slot.containsHour(9))
    }

    @Test("Normal range: 6-12 does NOT contain 13")
    func normalRangeOutside() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        #expect(!slot.containsHour(13))
    }

    @Test("Normal range: start boundary is inclusive")
    func normalRangeStartBoundary() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        #expect(slot.containsHour(6))
    }

    @Test("Normal range: end boundary is exclusive")
    func normalRangeEndBoundary() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        #expect(!slot.containsHour(12))
    }

    @Test("Wrapping range: 22-6 contains 23")
    func wrappingRangeLateNight() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        #expect(slot.containsHour(23))
    }

    @Test("Wrapping range: 22-6 contains 3 (after midnight)")
    func wrappingRangeEarlyMorning() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        #expect(slot.containsHour(3))
    }

    @Test("Wrapping range: 22-6 does NOT contain 12")
    func wrappingRangeOutside() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        #expect(!slot.containsHour(12))
    }

    @Test("Wrapping range: 22-6 contains 0 (midnight)")
    func wrappingRangeMidnight() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        #expect(slot.containsHour(0))
    }

    @Test("Default slots cover all 24 hours")
    func defaultSlotsCoverAllHours() {
        let slots = ScheduleSlot.defaultSlots
        for hour in 0..<24 {
            let covered = slots.contains { $0.containsHour(hour) }
            #expect(covered, "Hour \(hour) is not covered by any default slot")
        }
    }
}

// MARK: - VideoEffectConfig Tests

@Suite("VideoEffectConfig")
struct VideoEffectConfigTests {

    @Test("Default config has no active effects")
    func defaultNoActiveEffects() {
        let config = VideoEffectConfig.default
        #expect(!config.hasActiveEffect)
    }

    @Test("Blur triggers active effect")
    func blurActive() {
        var config = VideoEffectConfig.default
        config.blurRadius = 5
        #expect(config.hasActiveEffect)
    }

    @Test("Saturation != 1 triggers active effect")
    func saturationActive() {
        var config = VideoEffectConfig.default
        config.saturation = 0.5
        #expect(config.hasActiveEffect)
    }

    @Test("Auto time tint triggers active effect")
    func autoTimeTintActive() {
        var config = VideoEffectConfig.default
        config.autoTimeTint = true
        #expect(config.hasActiveEffect)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var config = VideoEffectConfig()
        config.blurRadius = 10
        config.saturation = 0.8
        config.brightness = -0.2
        config.warmth = 4000
        config.vignetteIntensity = 3
        config.autoTimeTint = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: data)

        #expect(decoded == config)
    }
}

// MARK: - FilterParameters Tests

@Suite("FilterParameters")
struct FilterParametersTests {

    @Test("Immutable snapshot from config")
    func snapshotFromConfig() {
        var config = VideoEffectConfig.default
        config.blurRadius = 15
        config.warmth = 4000

        let params = FilterParameters(from: config)
        #expect(params.blurRadius == 15)
        #expect(params.warmth == 4000)
        #expect(params.saturation == 1.0)
    }
}
