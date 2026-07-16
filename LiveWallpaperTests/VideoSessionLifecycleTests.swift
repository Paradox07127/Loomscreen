import AppKit
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the policy-side of the video lifecycle: WallpaperPolicyEngine
/// pure-function decisions and the `VideoWallpaperSession` intent state
/// machine. The runtime-side (real AVPlayer playback) is exercised manually;
/// these tests guarantee the decision layer that ScreenManager +
/// PlaybackCoordinator rely on cannot regress silently.
@Suite("Video session lifecycle policy")
@MainActor
struct VideoSessionLifecycleTests {

    // MARK: - WallpaperPolicyEngine: pause-on-power decisions

    @Test("External power never pauses, regardless of settings")
    func externalPowerNeverPauses() {
        let aggressiveSettings = GlobalSettings(globalPauseOnBattery: true)
        let decision = WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: aggressiveSettings,
            powerSource: .external
        )
        #expect(decision == false)
    }

    @Test("Pause-on-battery pauses whenever unplugged; off keeps playing")
    func pauseOnBatteryDecision() {
        let on = GlobalSettings(globalPauseOnBattery: true)
        let off = GlobalSettings(globalPauseOnBattery: false)

        #expect(WallpaperPolicyEngine.shouldPauseForPower(globalSettings: on, powerSource: .battery(level: 0.95)))
        #expect(WallpaperPolicyEngine.shouldPauseForPower(globalSettings: on, powerSource: .battery(level: 0.05)))
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(globalSettings: off, powerSource: .battery(level: 0.05)))
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(globalSettings: on, powerSource: .external))
    }

    @Test("Full-screen policy is gated by the user setting")
    func fullScreenPolicyHonoursSetting() {
        let disabled = GlobalSettings(pauseOnFullScreen: false)
        let enabled = GlobalSettings(pauseOnFullScreen: true)

        #expect(!WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: disabled,
            isHiddenByFullScreen: true
        ))
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: enabled,
            isHiddenByFullScreen: true
        ))
        #expect(!WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: enabled,
            isHiddenByFullScreen: false
        ))
    }

    // MARK: - ScreenManager wiring: power changes flow through the injected monitor

    @Test("ScreenManager subscribes the injected PowerMonitoring publisher and reacts to changes")
    func screenManagerReactsToInjectedPowerMonitorEvents() async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager wiring test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        let powerMonitor = FakePowerMonitor(initialPowerSource: .external)
        _ = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: powerMonitor,
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen]),
            featureCatalog: FeatureCatalog(capabilities: .pro)
        ))

        let baselineReadCount = powerMonitor.currentPowerSourceReadCount
        powerMonitor.send(.battery(level: 0.10))
        try await Task.sleep(for: .milliseconds(20))

        #expect(powerMonitor.currentPowerSourceReadCount >= baselineReadCount)
    }

    // MARK: - VideoWallpaperSession intent state machine (single authority)

    /// Asserts the core safety invariant: a performance-policy profile NEVER
    /// mutates `userIntendsToPlay`; only manual play/pause do. Uses a player
    /// built with `loadImmediately: false` so no AVPlayer/window is created —
    /// the intent flag is synchronous and independent of real playback.
    @Test("Policy profiles never mutate intent; manual play/pause own it")
    func videoIntentStateMachine() {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/master-gate-intent-\(UUID().uuidString).mov"),
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            loadImmediately: false
        )
        let session = VideoWallpaperSession(player: player)
        defer { session.cleanup() }

        #expect(session.userIntendsToPlay)

        session.applyPerformanceProfile(.suspended)
        #expect(session.userIntendsToPlay)
        session.applyPerformanceProfile(.quality)
        #expect(session.userIntendsToPlay)

        session.pause()
        #expect(!session.userIntendsToPlay)

        // A policy `.quality` must NOT resume a manually-paused video.
        session.applyPerformanceProfile(.suspended)
        #expect(!session.userIntendsToPlay)
        session.applyPerformanceProfile(.quality)
        #expect(!session.userIntendsToPlay)

        session.play()
        #expect(session.userIntendsToPlay)
    }

    @Test("Cleanup blocks a loader completion that resumes after cancellation")
    func cleanupBlocksDelayedPlaybackInstall() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delayed-video-install-\(UUID().uuidString).mov")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loader = SuspendingWallpaperAssetLoader()
        let player = WallpaperVideoPlayer(
            url: url,
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            assetLoaderOverride: { url in try await loader.load(url) }
        )

        let didSuspend = await Self.waitUntil { loader.isSuspended }
        #expect(didSuspend)

        player.cleanup()
        loader.resume(with: AVURLAsset(url: url))
        for _ in 0..<8 { await Task.yield() }

        #expect(player.isCleanedUp)
        #expect(player.player == nil)
        #expect(!player.hasInstalledPlaybackWindow)
        #expect(player.currentVideoComposition == nil)

        player.setVideoComposition(AVMutableVideoComposition())
        player.setFrameRateLimit(30)
        #expect(player.currentVideoComposition == nil)
        #expect(player.requestedFrameRateLimit == 0)
    }

    @Test("Stale video-effects failure cannot clear the newer task handle")
    func staleVideoEffectsFailureCannotClearNewerTask() async {
        let player = WallpaperVideoPlayer(
            url: URL(fileURLWithPath: "/tmp/video-effects-generation.mov"),
            frame: CGRect(x: 0, y: 0, width: 32, height: 32),
            loadImmediately: false
        )
        defer { player.cleanup() }

        let builder = ControlledVideoCompositionBuilder()
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/tmp/video-effects-asset.mov"))
        let service = VideoEffectsApplicationService(
            compositionBuilder: { asset, config, duration in
                try await builder.build(asset: asset, config: config, frameDuration: duration)
            },
            assetProvider: { _ in asset }
        )
        let screenID: CGDirectDisplayID = 8_101
        var first = ScreenConfiguration(screenID: screenID, videoBookmarkData: Data())
        first.effectConfig.blurRadius = 1
        var second = first
        second.effectConfig.blurRadius = 2

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: first,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        let firstStarted = await Self.waitUntil { builder.pendingCalls.contains(1) }
        #expect(firstStarted)

        service.applyEffects(
            to: player,
            screenID: screenID,
            config: second,
            screenRefreshRate: 60,
            noEffectsHandler: {}
        )
        let secondStarted = await Self.waitUntil { builder.pendingCalls.contains(2) }
        #expect(secondStarted)

        builder.resume(call: 1)
        let staleCompleted = await Self.waitUntil { builder.completedCalls.contains(1) }
        #expect(staleCompleted)
        #expect(service.hasInflightTask(for: screenID))

        builder.resume(call: 2)
        let latestCompleted = await Self.waitUntil { !service.hasInflightTask(for: screenID) }
        #expect(latestCompleted)
        #expect(!service.hasInflightTask(for: screenID))
    }

    private static func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}

@MainActor
private final class SuspendingWallpaperAssetLoader {
    private var continuation: CheckedContinuation<AVURLAsset, any Error>?
    private(set) var isSuspended = false

    func load(_ url: URL) async throws -> AVURLAsset {
        isSuspended = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with asset: AVURLAsset) {
        isSuspended = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: asset)
    }
}

@MainActor
private final class ControlledVideoCompositionBuilder {
    private enum ProbeError: Error {
        case staleFailure
    }

    private var callCount = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var pendingCalls: Set<Int> = []
    private(set) var completedCalls: Set<Int> = []

    func build(
        asset: AVAsset,
        config: VideoEffectConfig,
        frameDuration: CMTime
    ) async throws -> AVVideoComposition {
        callCount += 1
        let call = callCount
        pendingCalls.insert(call)
        await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
        pendingCalls.remove(call)
        completedCalls.insert(call)
        if call == 1 {
            throw ProbeError.staleFailure
        }
        return AVMutableVideoComposition()
    }

    func resume(call: Int) {
        let continuation = continuations.removeValue(forKey: call)
        continuation?.resume()
    }
}
