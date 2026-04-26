import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("WallpaperSessionDefinition")
struct WallpaperSessionDefinitionTests {

    @Test("Remote HTML configuration resolves into a typed session definition")
    func remoteHTMLConfigurationResolves() {
        let configuration = ScreenConfiguration(
            screenID: 11,
            videoBookmarkData: Data(),
            wallpaperType: .html,
            htmlContent: "https://example.com/wallpaper"
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.remoteURL(URL(string: "https://example.com/wallpaper")!)))
    }

    @Test("Local HTML configuration resolves into a typed session definition")
    func localHTMLConfigurationResolves() throws {
        let localFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("html")
        try Data("<html></html>".utf8).write(to: localFile)

        let configuration = ScreenConfiguration(
            screenID: 12,
            videoBookmarkData: Data(),
            wallpaperType: .html,
            htmlContent: localFile.path
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.localFile(localFile)))
    }

    @Test("Inline HTML configuration resolves into a typed session definition")
    func inlineHTMLConfigurationResolves() {
        let configuration = ScreenConfiguration(
            screenID: 13,
            videoBookmarkData: Data(),
            wallpaperType: .html,
            htmlContent: "<html><body>Inline</body></html>"
        )

        let definition = WallpaperSessionDefinition(configuration: configuration)

        #expect(definition == .html(.inlineHTML("<html><body>Inline</body></html>")))
    }

    @Test("Session definition display names come from typed content")
    func sessionDefinitionDisplayNameUsesTypedContent() {
        let definitions: [WallpaperSessionDefinition] = [
            .html(.remoteURL(URL(string: "https://example.com/live")!)),
            .html(.localFile(URL(fileURLWithPath: "/tmp/demo.html"))),
            .html(.inlineHTML("<html></html>")),
            .metalShader(.aurora),
            .video(bookmarkData: Data([0x01, 0x02])),
        ]

        let displayNames = definitions.map { definition in
            definition.displayName(using: { _ in "Demo.mov" })
        }

        #expect(displayNames[0] == "example.com")
        #expect(displayNames[1] == "demo.html")
        #expect(displayNames[2] == "Inline HTML")
        #expect(displayNames[3] == "Aurora")
        #expect(displayNames[4] == "Demo.mov")
    }
}

@Suite("WallpaperStatusAggregator")
struct WallpaperStatusAggregatorTests {

    @Test("HTML wallpaper counts as configured and active")
    func htmlWallpaperCountsAsActive() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .html,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "https://example.com"
            )
        ]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .active)
    }

    @Test("Paused video with no active sessions reports paused")
    func pausedVideoReportsPaused() {
        let summaries = [
            WallpaperSessionSummary(
                wallpaperType: .video,
                activity: .paused,
                supportsPlaybackControl: true,
                subtitle: "Demo.mp4"
            )
        ]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .paused)
    }

    @Test("No configured sessions reports not configured")
    func noConfiguredSessionsReportsNotConfigured() {
        let summaries = [WallpaperSessionSummary.notConfigured]

        let overview = WallpaperStatusAggregator.overview(for: summaries)

        #expect(overview == .notConfigured)
    }
}

@Suite("WallpaperConfigurationStore removing invalid video configurations")
struct WallpaperConfigurationStoreInvalidConfigTests {

    @Test("Invalid video configurations are removed while non-video wallpapers survive")
    func invalidVideoConfigurationsAreRemoved() {
        let configs = [
            ScreenConfiguration(screenID: 1, videoBookmarkData: Data([0x01]), wallpaperType: .video),
            ScreenConfiguration(screenID: 2, videoBookmarkData: Data(), wallpaperType: .html, htmlContent: "https://example.com"),
            ScreenConfiguration(screenID: 3, videoBookmarkData: Data(), wallpaperType: .metalShader, shaderPreset: .aurora),
        ]

        let pruned = WallpaperConfigurationStore.removingInvalidVideoConfigurations(
            from: configs,
            invalidScreenIDs: [1, 2, 3]
        )

        #expect(pruned.count == 2)
        #expect(pruned.contains(where: { $0.screenID == 2 && $0.wallpaperType == .html }))
        #expect(pruned.contains(where: { $0.screenID == 3 && $0.wallpaperType == .metalShader }))
        #expect(!pruned.contains(where: { $0.screenID == 1 }))
    }
}

@Suite("WallpaperPolicyEngine")
struct WallpaperPolicyEngineTests {

    @Test("On battery without pause-on-battery: profile stays quality; no pause requested")
    func batteryStaticProfile() {
        let settings = GlobalSettings(globalPauseOnBattery: false)

        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: settings,
            powerSource: .battery(level: 80),
            isHiddenByFullScreen: false
        )

        // Battery no longer produces a degraded-animation state — the UX is
        // static-on-battery, driven by `shouldPauseForPower` when enabled.
        #expect(profile == .quality)
        #expect(!WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            configuration: nil,
            powerSource: .battery(level: 80)
        ))
    }

    @Test("Fullscreen hidden screen maps to suspended profile")
    func fullScreenSuspendedProfile() {
        let settings = GlobalSettings(pauseOnFullScreen: true)

        let profile = WallpaperPolicyEngine.performanceProfile(
            globalSettings: settings,
            powerSource: .external,
            isHiddenByFullScreen: true
        )

        #expect(profile == .suspended)
        #expect(WallpaperPolicyEngine.shouldApplyFullScreenPolicy(
            globalSettings: settings,
            isHiddenByFullScreen: true
        ))
    }

    @Test("Global pause on battery pauses video playback")
    func globalPauseOnBatteryDecision() {
        let settings = GlobalSettings(globalPauseOnBattery: true)

        #expect(WallpaperPolicyEngine.shouldPauseForPower(
            globalSettings: settings,
            configuration: nil,
            powerSource: .battery(level: 90)
        ))
        #expect(WallpaperPolicyEngine.shouldResumeFromPower(
            powerSource: .external,
            wasPausedByPower: true
        ))
    }

    @Test("Fullscreen fallback polling only runs when fullscreen policy can affect sessions")
    func fullScreenFallbackPollingDecision() {
        #expect(WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: true
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: false),
            hasConfiguredWallpaperSessions: true
        ))
        #expect(!WallpaperPolicyEngine.shouldEnableFullScreenFallbackPolling(
            globalSettings: GlobalSettings(pauseOnFullScreen: true),
            hasConfiguredWallpaperSessions: false
        ))
    }
}

@Suite("FullScreenDetector adaptive polling")
@MainActor
struct FullScreenDetectorAdaptivePollingTests {

    @Test("Detector starts notification-only and toggles fallback polling explicitly")
    func fallbackPollingTogglesExplicitly() {
        let detector = FullScreenDetector(pollInterval: 60)

        #expect(!detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(true)
        #expect(detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(true)
        #expect(detector.isFallbackPollingEnabled)

        detector.setFallbackPollingEnabled(false)
        #expect(!detector.isFallbackPollingEnabled)

        detector.stop()
    }
}

@Suite("PlaylistPolicy")
struct PlaylistPolicyTests {

    @Test("Sequential cursor advances 0 → 1 → 2 → 0")
    func sequentialCursorAdvances() {
        // Covers the regression where the old primary-based API stalled after
        // one rotation when primary coincided with a playlist entry.
        let count = 3

        let step1 = PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: count, shuffle: false)
        let step2 = PlaylistPolicy.nextCursor(currentCursor: 1, playlistCount: count, shuffle: false)
        let step3 = PlaylistPolicy.nextCursor(currentCursor: 2, playlistCount: count, shuffle: false)

        #expect(step1 == 1)
        #expect(step2 == 2)
        #expect(step3 == 0)
    }

    @Test("Playlist with fewer than two entries does not rotate")
    func tooFewEntriesDoesNotRotate() {
        #expect(PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: 1, shuffle: false) == nil)
        #expect(PlaylistPolicy.nextCursor(currentCursor: 0, playlistCount: 0, shuffle: true) == nil)
    }

    @Test("Shuffle excludes the currently playing cursor")
    func shuffleExcludesCurrentCursor() {
        // randomIndex returns the current cursor → policy must bump to a
        // different index so we never replay the same video.
        let next = PlaylistPolicy.nextCursor(
            currentCursor: 2,
            playlistCount: 4,
            shuffle: true,
            randomIndex: { _ in 2 }
        )

        #expect(next != 2)
        #expect(next != nil)
    }

    @Test("Stale cursor (past end) normalizes before advancing")
    func staleCursorNormalizes() {
        // Persisted cursor 7 against a 3-entry playlist → normalize to 7 % 3 = 1,
        // advance to 2.
        let next = PlaylistPolicy.nextCursor(currentCursor: 7, playlistCount: 3, shuffle: false)
        #expect(next == 2)
    }

    @Test("combinedPlaylist returns nil when only primary exists")
    func combinedPlaylistNilWithOneEntry() {
        #expect(PlaylistPolicy.combinedPlaylist(primary: Data([0x01]), additional: nil) == nil)
        #expect(PlaylistPolicy.combinedPlaylist(primary: Data([0x01]), additional: []) == nil)
    }

    @Test("combinedPlaylist composes primary + additional when more than one entry")
    func combinedPlaylistComposes() {
        let primary = Data([0x01])
        let extras = [Data([0x02]), Data([0x03])]
        let combined = PlaylistPolicy.combinedPlaylist(primary: primary, additional: extras)
        #expect(combined == [primary, extras[0], extras[1]])
    }

    @Test("Playlist rotation waits until configured interval elapses")
    func playlistRotationInterval() {
        let lastRotation = Date(timeIntervalSince1970: 100)

        #expect(!PlaylistPolicy.shouldRotate(
            now: Date(timeIntervalSince1970: 159),
            lastRotation: lastRotation,
            rotationMinutes: 1
        ))
        #expect(PlaylistPolicy.shouldRotate(
            now: Date(timeIntervalSince1970: 160),
            lastRotation: lastRotation,
            rotationMinutes: 1
        ))
    }
}

// MARK: - ScreenConfiguration rotation / schedule / replace-primary integration

@Suite("ScreenConfiguration playlist + schedule helpers")
struct ScreenConfigurationHelpersTests {

    @Test("replacePrimaryVideo preserves effects/playlist/schedule")
    func replacePrimaryVideoPreservesSettings() {
        var effects = VideoEffectConfig.default
        effects.saturation = 0.7
        let oldBookmark = Data([0x01])
        let newBookmark = Data([0x99])

        var config = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: oldBookmark,
            particleEffect: .snow,
            effectConfig: effects,
            scheduleSlots: ScheduleSlot.defaultSlots,
            playlistBookmarks: [Data([0x02]), Data([0x03])],
            shufflePlaylist: true,
            playlistRotationMinutes: 15,
            playlistCursorIndex: 2
        )

        config.replacePrimaryVideo(bookmarkData: newBookmark)

        #expect(config.savedVideoBookmarkData == newBookmark)
        #expect(config.activeWallpaper == .video(bookmarkData: newBookmark))
        #expect(config.playlistCursorIndex == 0) // reset so cursor isn't stale
        // Everything else preserved:
        #expect(config.particleEffect == .snow)
        #expect(config.effectConfig.saturation == 0.7)
        #expect(config.scheduleSlots?.count == ScheduleSlot.defaultSlots.count)
        #expect(config.playlistBookmarks == [Data([0x02]), Data([0x03])])
        #expect(config.shufflePlaylist == true)
        #expect(config.playlistRotationMinutes == 15)
    }

    @Test("applyScheduledBookmark preserves savedVideoBookmarkData (primary)")
    func applyScheduledBookmarkPreservesPrimary() {
        let primary = Data([0x01])
        let scheduled = Data([0xAA])

        var config = ScreenConfiguration(
            screenID: 2,
            videoBookmarkData: primary,
            particleEffect: .rain,
            effectConfig: .default,
            playlistBookmarks: [Data([0xBB])],
            playlistCursorIndex: 1
        )

        config.applyScheduledBookmark(scheduled)

        #expect(config.activeWallpaper == .video(bookmarkData: scheduled))
        #expect(config.savedVideoBookmarkData == primary, "primary survives schedule")
        #expect(config.playlistCursorIndex == 1, "cursor survives schedule")
        #expect(config.particleEffect == .rain)
        #expect(config.playlistBookmarks == [Data([0xBB])])
    }

    @Test("withUpdatedActiveBookmark refreshes primary when cursor=0")
    func withUpdatedActiveBookmarkAtPrimary() {
        let config = ScreenConfiguration(
            screenID: 3,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 0
        )
        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)
        #expect(updated.savedVideoBookmarkData == refreshed)
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.playlistBookmarks == [Data([0x02])]) // untouched
    }

    @Test("withUpdatedActiveBookmark refreshes the playlist slot it matches and leaves primary alone")
    func withUpdatedActiveBookmarkAtPlaylistSlot() {
        let primary = Data([0x01])
        let playlistEntry = Data([0x03])
        var config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: primary,
            playlistBookmarks: [Data([0x02]), playlistEntry],
            playlistCursorIndex: 2
        )
        // Simulate "currently playing playlist[1]" — what advancePlaylist does.
        config.activeWallpaper = .video(bookmarkData: playlistEntry)

        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)

        #expect(updated.savedVideoBookmarkData == primary, "primary must not be clobbered")
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.playlistBookmarks == [Data([0x02]), refreshed])
    }

    @Test("withUpdatedActiveBookmark refreshes the schedule slot it matches and leaves primary alone")
    func withUpdatedActiveBookmarkAtScheduleSlot() {
        let primary = Data([0x01])
        let scheduledBookmark = Data([0xAA])
        var config = ScreenConfiguration(
            screenID: 5,
            videoBookmarkData: primary,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduledBookmark, label: "Morning")
            ]
        )
        // Simulate "currently playing the morning schedule slot".
        config.activeWallpaper = .video(bookmarkData: scheduledBookmark)

        let refreshed = Data([0xFE])
        let updated = config.withUpdatedActiveBookmark(refreshed)

        #expect(updated.savedVideoBookmarkData == primary, "primary must not be clobbered by stale schedule refresh")
        #expect(updated.activeWallpaper == .video(bookmarkData: refreshed))
        #expect(updated.scheduleSlots?.first?.videoBookmarkData == refreshed)
    }

    @Test("playlistCursorIndex survives Codable round-trip")
    func playlistCursorIndexRoundTrip() throws {
        let original = ScreenConfiguration(
            screenID: 5,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)
        #expect(decoded.playlistCursorIndex == 1)
    }

    @Test("activateSavedVideoWallpaper resets cursor to 0")
    func activateSavedVideoResetsCursor() {
        let primary = Data([0x01])
        var config = ScreenConfiguration(
            screenID: 6,
            videoBookmarkData: primary,
            playlistBookmarks: [Data([0x02])],
            playlistCursorIndex: 1
        )
        config.setHTMLWallpaper("https://example.com")
        _ = config.activateSavedVideoWallpaper()
        #expect(config.playlistCursorIndex == 0)
        #expect(config.activeWallpaper == .video(bookmarkData: primary))
    }
}

@Suite("SchedulePolicy")
struct SchedulePolicyTests {

    @Test("Schedule policy returns active slot bookmark")
    func schedulePolicyReturnsBookmark() {
        let current = Data([0x01])
        let scheduled = Data([0x02])
        let configuration = ScreenConfiguration(
            screenID: 41,
            videoBookmarkData: current,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: scheduled, label: "Morning")
            ]
        )

        let result = SchedulePolicy.scheduledBookmark(in: configuration, hour: 8)

        #expect(result?.slot.label == "Morning")
        #expect(result?.bookmarkData == scheduled)
    }

    @Test("Schedule policy skips already active bookmark")
    func schedulePolicySkipsAlreadyActiveBookmark() {
        let bookmark = Data([0x01])
        let configuration = ScreenConfiguration(
            screenID: 42,
            videoBookmarkData: bookmark,
            scheduleSlots: [
                ScheduleSlot(startHour: 6, endHour: 12, videoBookmarkData: bookmark, label: "Morning")
            ]
        )

        let result = SchedulePolicy.scheduledBookmark(in: configuration, hour: 8)

        #expect(result == nil)
    }
}

@Suite("Screen runtime ownership")
@MainActor
struct ScreenRuntimeOwnershipTests {

    @Test("Screen reads summary and cleanup state from installed runtime session")
    func screenUsesInstalledRuntimeSession() {
        guard let nsScreen = NSScreen.screens.first else {
            Issue.record("No NSScreen available for test")
            return
        }

        let screen = Screen(nsScreen: nsScreen)
        let session = TestWallpaperRuntimeSession(
            summary: WallpaperSessionSummary(
                wallpaperType: .metalShader,
                activity: .active,
                supportsPlaybackControl: false,
                subtitle: "Aurora"
            ),
            wallpaperType: .metalShader
        )

        screen.installRuntimeSession(session)

        #expect(screen.wallpaperSessionSummary == session.summary)
        #expect(screen.activeWallpaperType == .metalShader)
        #expect(screen.videoPlayer == nil)

        screen.resetRuntimeSession()

        #expect(session.cleanupCallCount == 1)
        #expect(screen.wallpaperSessionSummary == .notConfigured)
        #expect(screen.activeWallpaperWindow == nil)
    }
}

@MainActor
private final class TestWallpaperRuntimeSession: WallpaperRuntimeSession {
    let wallpaperType: WallpaperType
    let summary: WallpaperSessionSummary
    let videoPlayer: WallpaperVideoPlayer? = nil
    let wallpaperWindow: NSWindow? = nil
    private(set) var cleanupCallCount = 0

    init(summary: WallpaperSessionSummary, wallpaperType: WallpaperType) {
        self.summary = summary
        self.wallpaperType = wallpaperType
    }

    func updateFrame(to frame: CGRect) {}

    func show() {}

    func hide() {}

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {}

    func cleanup() {
        cleanupCallCount += 1
    }
}
