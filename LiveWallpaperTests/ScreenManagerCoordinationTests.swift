import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

/// Validates the surface that PlaybackCoordinator extraction is meant to
/// preserve: the per-screen transition registry plus the four configuration
/// setters that ScreenManager forwards through the coordinator. Pure
/// unit-level coverage; runtime-session heavy paths live in the dedicated
/// session-lifecycle suites.
@Suite("ScreenManager ↔ PlaybackCoordinator coordination")
@MainActor
struct ScreenManagerCoordinationTests {

    // MARK: - PlaybackTransitionRegistry

    @Test("bumpTransition starts at 1 and increments monotonically per screen")
    func bumpTransitionIncrementsMonotonically() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 100

        #expect(registry.bumpTransition(for: screenID) == 1)
        #expect(registry.bumpTransition(for: screenID) == 2)
        #expect(registry.bumpTransition(for: screenID) == 3)
    }

    @Test("Each screen ID has an independent generation counter")
    func transitionGenerationsAreIndependentPerScreen() {
        let registry = PlaybackTransitionRegistry()

        #expect(registry.bumpTransition(for: 100) == 1)
        #expect(registry.bumpTransition(for: 200) == 1)
        #expect(registry.bumpTransition(for: 100) == 2)
        #expect(registry.bumpTransition(for: 200) == 2)
    }

    @Test("isCurrentTransition rejects stale generations")
    func isCurrentTransitionRejectsStaleGenerations() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 300

        let stale = registry.bumpTransition(for: screenID)
        let current = registry.bumpTransition(for: screenID)

        #expect(registry.isCurrentTransition(current, for: screenID))
        #expect(!registry.isCurrentTransition(stale, for: screenID))
    }

    @Test("cancelAssetReadiness cancels the installed work")
    func cancelAssetReadinessCancelsInstalledWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 400
        let task = Self.makeSuspendedTask()
        defer { task.cancel() }

        registry.setAssetReadiness(Self.makeWork(task: task), for: screenID)
        registry.cancelAssetReadiness(for: screenID)

        #expect(task.isCancelled)
    }

    @Test("cancelAssetReadiness is harmless when no work is installed")
    func cancelAssetReadinessOnEmptySlotIsNoOp() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 401
        let task = Self.makeSuspendedTask()
        defer {
            task.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.cancelAssetReadiness(for: screenID)
        registry.setAssetReadiness(Self.makeWork(task: task), for: screenID)

        #expect(!task.isCancelled)
    }

    @Test("setAssetReadiness cancels prior work when replacing")
    func setAssetReadinessCancelsPriorWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 500
        let priorTask = Self.makeSuspendedTask()
        let replacementTask = Self.makeSuspendedTask()
        defer {
            priorTask.cancel()
            replacementTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(Self.makeWork(task: priorTask), for: screenID)
        registry.setAssetReadiness(Self.makeWork(task: replacementTask), for: screenID)

        #expect(priorTask.isCancelled)
        #expect(!replacementTask.isCancelled)
    }

    @Test("clearAssetReadinessIfMatch removes the matching installed work")
    func clearAssetReadinessIfMatchRemovesMatchingWork() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 600
        let installedTask = Self.makeSuspendedTask()
        let installedWork = Self.makeWork(task: installedTask)
        let replacementTask = Self.makeSuspendedTask()
        defer {
            installedTask.cancel()
            replacementTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(installedWork, for: screenID)
        registry.clearAssetReadinessIfMatch(installedWork, for: screenID)

        // After a successful match-clear the slot must be empty: a follow-up
        // set should NOT cancel the previously cleared work, and the original
        // task must remain alive (it was never cancelled by the registry).
        registry.setAssetReadiness(Self.makeWork(task: replacementTask), for: screenID)

        withExtendedLifetime(installedWork) {
            #expect(!installedTask.isCancelled)
        }
        #expect(!replacementTask.isCancelled)
    }

    @Test("clearAssetReadinessIfMatch is a no-op when a newer work has replaced the slot")
    func clearAssetReadinessIfMatchIgnoresStaleHandle() {
        let registry = PlaybackTransitionRegistry()
        let screenID: CGDirectDisplayID = 601
        let originalWork = AssetReadinessWork()
        let newerTask = Self.makeSuspendedTask()
        let newerWork = Self.makeWork(task: newerTask)
        defer {
            newerTask.cancel()
            registry.cancelAssetReadiness(for: screenID)
        }

        registry.setAssetReadiness(originalWork, for: screenID)
        registry.setAssetReadiness(newerWork, for: screenID)
        registry.clearAssetReadinessIfMatch(originalWork, for: screenID)

        // If the stale clear were honoured the slot would be empty; a follow-up
        // replacement would no longer cancel `newerWork`. Verifying the inverse
        // proves the slot still holds `newerWork`.
        let followupTask = Self.makeSuspendedTask()
        defer { followupTask.cancel() }
        registry.setAssetReadiness(Self.makeWork(task: followupTask), for: screenID)

        #expect(newerTask.isCancelled)
    }

    // MARK: - ScreenManager → PlaybackCoordinator setter forwarding

    @Test("updatePlaybackSpeed mutates configuration and posts a change notification")
    func updatePlaybackSpeedForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let target = Self.differentValue(
                from: manager.getConfiguration(for: screen)?.playbackSpeed,
                options: [0.5, 0.75, 1.0, 1.5]
            )
            try await Self.expectChange(notificationFor: screen) {
                manager.updatePlaybackSpeed(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.playbackSpeed == target)
        }
    }

    @Test("updateMuted mutates configuration and posts a change notification")
    func updateMutedForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.muted ?? true
            let target = !current
            try await Self.expectChange(notificationFor: screen) {
                manager.updateMuted(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.muted == target)
        }
    }

    @Test("updateFitMode mutates configuration and posts a change notification")
    func updateFitModeForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.fitMode ?? .aspectFill
            let target: VideoFitMode = current == .aspectFill ? .aspectFit : .aspectFill
            try await Self.expectChange(notificationFor: screen) {
                manager.updateFitMode(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.fitMode == target)
        }
    }

    @Test("updateFrameRateLimit mutates configuration and posts a change notification")
    func updateFrameRateLimitForwardsThroughCoordinator() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            let current = manager.getConfiguration(for: screen)?.frameRateLimit ?? .fps60
            let target: FrameRateLimit = current == .fps60 ? .fps30 : .fps60
            try await Self.expectChange(notificationFor: screen) {
                manager.updateFrameRateLimit(target, for: screen)
            }
            #expect(manager.getConfiguration(for: screen)?.frameRateLimit == target)
        }
    }

    @Test("Re-applying the current playback speed is a no-op (no notification)")
    func updatePlaybackSpeedWithSameValueIsNoOp() async throws {
        try await Self.runWithSeededConfiguration { manager, screen in
            guard let currentSpeed = manager.getConfiguration(for: screen)?.playbackSpeed else {
                Issue.record("Seeded configuration is missing playbackSpeed")
                return
            }
            let capture = Self.attachConfigurationObserver()
            defer { capture.detach() }

            manager.updatePlaybackSpeed(currentSpeed, for: screen)
            await Self.drainMainQueue()

            #expect(capture.notifications.isEmpty)
            #expect(manager.getConfiguration(for: screen)?.playbackSpeed == currentSpeed)
        }
    }

    // MARK: - Helpers

    private static func makeSuspendedTask() -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private static func makeWork(task: Task<Void, Never>) -> AssetReadinessWork {
        let work = AssetReadinessWork()
        work.fallbackTask = task
        return work
    }

    private static func differentValue<T: Equatable>(from current: T?, options: [T]) -> T {
        precondition(!options.isEmpty, "differentValue requires a non-empty option set")
        if let current, let next = options.first(where: { $0 != current }) {
            return next
        }
        return options[0]
    }

    /// Boots a `ScreenManager` with the four protocol fakes, ensures a
    /// `ScreenConfiguration` exists for the host's primary screen, and runs
    /// the closure. Snapshots and restores the persisted configuration so the
    /// test never overwrites the developer's real wallpaper preferences.
    /// Skips gracefully when the test runner has no NSScreen.
    private static func runWithSeededConfiguration(
        _ body: (ScreenManager, Screen) async throws -> Void
    ) async throws {
        guard let screen = NSScreen.screens.first.map(Screen.init(nsScreen:)) else {
            Issue.record("No NSScreen available for ScreenManager coordination test")
            return
        }
        let originalConfigurations = SettingsManager.shared.loadConfigurations()
        defer { SettingsManager.shared.replaceAllConfigurations(originalConfigurations) }

        if !originalConfigurations.contains(where: { $0.screenID == screen.id }) {
            // Direct seed avoids `setShaderWallpaper`'s real Metal/runtime side
            // effects; we only need a persisted ScreenConfiguration so the
            // PlaybackCoordinator's setters have something to mutate.
            SettingsManager.shared.saveConfiguration(
                ScreenConfiguration(screenID: screen.id, wallpaper: .metalShader(.waves))
            )
        }

        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(screens: [screen])
        ))

        guard manager.getConfiguration(for: screen) != nil else {
            Issue.record("Could not seed a ScreenConfiguration for the host screen")
            return
        }

        try await body(manager, screen)
    }

    /// Snapshots notifications observed during `mutation`, asserting exactly
    /// one new `.wallpaperConfigurationDidChange` for the given screen.
    private static func expectChange(
        notificationFor screen: Screen,
        _ mutation: () -> Void
    ) async throws {
        let capture = attachConfigurationObserver()
        defer { capture.detach() }

        mutation()
        try await capture.waitForNotifications(count: 1, timeout: .milliseconds(500))

        #expect(capture.notifications.count == 1)
        #expect(capture.notifications.first?.screenID == screen.id)
    }

    private static func attachConfigurationObserver() -> ConfigurationNotificationCapture {
        ConfigurationNotificationCapture(name: .wallpaperConfigurationDidChange)
    }

    private static func drainMainQueue() async {
        // 100ms gives congested CI runners enough headroom to drain queued
        // notifications before we assert the absence of side effects.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(100))
        await Task.yield()
    }
}

/// Captures notifications synchronously on the posting thread. The
/// PlaybackCoordinator's setters run on `@MainActor`, so posts arrive on the
/// main thread; using a `nil` operation queue keeps the observer on that same
/// thread and sidesteps Swift 6 cross-isolation `@Sendable` requirements on
/// `Notification`.
private final class ConfigurationNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScreenChangeRecord] = []
    private var observer: NSObjectProtocol?

    init(name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let record = ScreenChangeRecord(
                screenID: ConfigurationNotificationCapture.screenID(from: notification)
            )
            self?.append(record)
        }
    }

    deinit {
        detach()
    }

    var notifications: [ScreenChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func waitForNotifications(count: Int, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if notifications.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func append(_ record: ScreenChangeRecord) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(record)
    }

    private static func screenID(from notification: Notification) -> CGDirectDisplayID? {
        let raw = notification.userInfo?["screenID"]
        if let direct = raw as? CGDirectDisplayID { return direct }
        if let number = raw as? NSNumber { return CGDirectDisplayID(number.uint32Value) }
        return nil
    }
}

private struct ScreenChangeRecord: Sendable {
    let screenID: CGDirectDisplayID?
}
