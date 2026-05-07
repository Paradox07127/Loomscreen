import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import LiveWallpaper

@Suite("Settings window layout")
struct SettingsWindowLayoutTests {
    @Test("Settings window defaults fit the minimum composed layout")
    func settingsWindowDefaultsFitMinimumComposedLayout() {
        #expect(SettingsWindowMetrics.defaultContentSize.width >= SettingsWindowMetrics.minimumContentSize.width)
        #expect(SettingsWindowMetrics.defaultContentSize.height >= SettingsWindowMetrics.minimumContentSize.height)
        #expect(SettingsWindowMetrics.sidebarColumnWidth == 210)
        #expect(SettingsWindowMetrics.sidebarColumnMaxWidth == SettingsWindowMetrics.sidebarColumnWidth * 1.15)
        #expect(SettingsWindowMetrics.minimumContentSize.width >= 1080)
        #expect(SettingsWindowMetrics.minimumContentSize.height >= 650)
        #expect(DesignTokens.Inspector.minWidth == 268)
        #expect(DesignTokens.Inspector.idealWidth == 292)
        #expect(DesignTokens.Inspector.maxWidth == 340)
    }

    @Test("Video inspector stacks mode controls above detail sections")
    func videoInspectorStacksModeControlsAboveDetailSections() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")
        let inspectorRange = try #require(
            source.range(of: "private var inspectorPanel"),
            "ScreenDetailView inspectorPanel not found"
        )
        let inspector = String(source[inspectorRange.lowerBound...])
        let videoBranchRange = try #require(
            inspector.range(of: "if selectedWallpaperType == .video {"),
            "Video inspector branch not found"
        )

        let branchBody = inspector[videoBranchRange.upperBound...]
            .drop(while: { $0.isWhitespace || $0.isNewline })
        #expect(
            branchBody.hasPrefix("VStack(spacing:"),
            "Video inspector detail sections must flow vertically; a horizontal root makes the settings window overflow."
        )
    }

    @Test("Screen detail gives horizontal growth to preview, not inspector")
    func screenDetailGivesHorizontalGrowthToPreviewNotInspector() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(!source.contains("HSplitView"), "HSplitView persists user-resized column widths and lets the inspector stretch.")
        #expect(source.contains("HStack(spacing: 0)"), "The preview and inspector should be composed with an explicit horizontal stack.")
        #expect(source.contains(".layoutPriority(1)"), "The preview column should be the only horizontal expansion target.")
        #expect(source.contains("@AppStorage(\"Inspector.Width\")"), "The inspector should remember an explicit user width instead of stretching with the window.")
        #expect(
            source.contains(".frame(width: inspectorPanelWidth)"),
            "The inspector should use a clamped stored width so wide windows enlarge only the preview area."
        )
        #expect(source.contains("InspectorResizeHandle"), "The inspector should be user-resizable without reintroducing HSplitView.")
    }

    @Test("Inspector resize handle previews width locally and exposes a drag affordance")
    func inspectorResizeHandlePreviewsWidthLocallyAndExposesDragAffordance() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(
            source.contains("@State private var liveInspectorWidth"),
            "Drag updates should live in transient view state instead of writing AppStorage every frame."
        )
        #expect(
            source.contains("DragGesture(minimumDistance: 2, coordinateSpace: .global)"),
            "The resize drag should use global coordinates so moving the handle does not change the drag coordinate space."
        )
        #expect(source.contains("onPreviewWidthChange"), "The handle should preview width during drag without committing it.")
        #expect(source.contains("onCommitWidth"), "The handle should persist the clamped width only when dragging ends.")
        #expect(source.contains("liveInspectorWidth = nil"), "The transient drag width should be cleared after commit.")
        #expect(
            source.contains("Image(systemName: \"arrow.left.and.right\")"),
            "The divider needs a visible centered affordance that communicates horizontal resizing."
        )
    }

    @Test("Playlist rows prioritize filename over secondary controls")
    func playlistRowsPrioritizeFilenameOverSecondaryControls() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/PlaylistSection.swift")

        #expect(source.contains(".layoutPriority(1)"), "Playlist filenames need first claim on row width.")
        #expect(source.contains(".help(entry.name)"), "Truncated filenames should still be discoverable via tooltip.")
        #expect(!source.contains("Button(action: onRemove)"), "A hidden remove button still consumes row width; removal belongs in the menu.")
        #expect(source.contains("Image(systemName: \"star.fill\")"), "Primary state should use a compact icon badge in narrow inspectors.")
    }

    @Test("Sidebar always exposes Workshop library entry")
    func sidebarAlwaysExposesWorkshopLibraryEntry() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")

        #expect(source.contains("NavigationLink(value: Navigation.workshop)"))
        #expect(source.contains("Label(\"Workshop Library\", systemImage: \"cube.transparent\")"))
        #expect(!source.contains("Label(\"Steam Workshop\", systemImage: \"cube.transparent\")"))
        #expect(!source.contains("workshopLibraryAvailable"))
        #expect(!source.contains("refreshWorkshopAvailability"))
    }

    @Test("Workshop and Aerials initial states omit inline headers")
    func workshopAndAerialsInitialStatesOmitInlineHeaders() throws {
        let workshopSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")
        let aerialsSource = try sourceText(for: "LiveWallpaper/Views/AppleAerialsLibraryView.swift")

        #expect(workshopSource.contains("if hasLibraryRoot {\n                header\n                Divider()\n            }"))
        #expect(!workshopSource.contains("case .needsRoot:\n            return \"Choose your Steam Wallpaper Engine folder to discover projects\""))
        #expect(aerialsSource.contains("if library.isAuthorized {\n                inlineHeader\n            }"))
    }

    @Test("Workshop and Aerials share the guide card layout")
    func workshopAndAerialsShareGuideCardLayout() throws {
        let workshopSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")
        let aerialsSource = try sourceText(for: "LiveWallpaper/Views/AppleAerialsLibraryView.swift")
        let sharedSource = try? sourceText(for: "LiveWallpaper/Views/LibraryGuideCard.swift")

        #expect(sharedSource?.contains("struct LibraryGuideCard") == true)
        #expect(workshopSource.contains("LibraryGuideCard("))
        #expect(aerialsSource.contains("LibraryGuideCard("))
        #expect(!workshopSource.contains("struct WorkshopGuideCard"))
        #expect(!aerialsSource.contains("struct UnauthorizedAerialsCard"))
    }

    @Test("Apple Aerials guide states do not keep the legacy card copy")
    func appleAerialsGuideStatesDoNotKeepLegacyCardCopy() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/AppleAerialsLibraryView.swift")

        #expect(source.contains("private func scanErrorView(message: String) -> some View {\n        LibraryGuideCard("))
        #expect(source.components(separatedBy: "LibraryGuideCard(").count >= 4)
        #expect(!source.contains("Opens the right folder automatically"))
        #expect(!source.contains("One click in the system dialog"))
        #expect(!source.contains("Read-only access to downloaded .mov aerials"))
        #expect(!source.contains("Read-only, .mov files only"))
    }

    @Test("Workshop gallery exposes root folder recovery controls")
    func workshopGalleryExposesRootFolderRecoveryControls() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")

        #expect(source.contains("Change Folder"))
        #expect(source.contains("Disconnect Workshop library"))
        #expect(source.contains("clearWorkshopLibraryRootBookmark()"))
        #expect(source.contains("updateRootAccessState()"))
    }

    @Test("Workshop gallery has guided empty states")
    func workshopGalleryHasGuidedEmptyStates() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")

        #expect(source.contains("LibraryGuideCard"))
        #expect(source.contains("No Workshop projects found"))
        #expect(source.contains("LibraryGuideFeature(icon: \"folder.badge.gearshape\""))
        #expect(source.contains("LibraryGuideFeature(icon: \"arrow.triangle.2.circlepath\""))
    }

    @Test("Expanded color inspector does not mount text input controls")
    func expandedColorInspectorDoesNotMountTextInputControls() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/ColorAdjustmentsView.swift")

        #expect(
            !source.contains("TextField("),
            "The expanded color inspector should not mount text inputs; numeric labels avoid activating InputMethodKit during normal settings runs."
        )
    }

    private func sourceText(for relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Suite("Video playback runtime hygiene")
struct VideoPlaybackRuntimeHygieneTests {
    @Test("Muted looper playback reapplies audio policy before autoplay")
    func mutedLooperPlaybackReappliesAudioPolicyBeforeAutoplay() throws {
        let source = try sourceText(for: "LiveWallpaper/VideoPlayback/WallpaperVideoPlayer.swift")

        #expect(source.contains("applyAudioPolicyToQueueItems()"), "Muted playback should disable audio tracks across looper clones.")
        #expect(source.contains("installQueueItemMaintenanceObserver()"), "New AVPlayerLooper items should receive the same muted audio policy.")
        #expect(source.contains("publisher(for: \\.currentItem)"), "The queue player current item should be observed as looper clones rotate.")
        #expect(
            source.contains("self.applyAudioPolicyToQueueItems()\n                self.play()"),
            "Audio tracks should be disabled again immediately before ready-time autoplay."
        )
    }

    private func sourceText(for relativePath: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - ResourceUtilities Tests

@Suite("ResourceUtilities") @MainActor
struct ResourceUtilitiesTests {

    @Test("Bookmark creation options match read-only sandbox entitlement")
    func bookmarkCreationOptionsAreReadOnlyScoped() {
        let options = ResourceUtilities.bookmarkCreationOptions

        #expect(options.contains(.withSecurityScope))
        #expect(options.contains(.securityScopeAllowOnlyReadAccess))
    }

    @Test("HTML folder index inference prefers standard names")
    func htmlFolderIndexInferencePrefersStandardNames() {
        let entries = ["about.html", "index.htm", "index.html"]

        let index = ResourceUtilities.inferHTMLIndexFileName(from: entries)

        #expect(index == "index.html")
    }

    @Test("HTML folder index inference falls back to first HTML file")
    func htmlFolderIndexInferenceFallsBackToFirstHTMLFile() {
        let entries = ["style.css", "landing.HTML", "script.js"]

        let index = ResourceUtilities.inferHTMLIndexFileName(from: entries)

        #expect(index == "landing.HTML")
    }

    @Test("HTML folder index inference preserves actual file name casing")
    func htmlFolderIndexInferencePreservesActualFileNameCasing() {
        let entries = ["Index.HTML", "about.html"]

        let index = ResourceUtilities.inferHTMLIndexFileName(from: entries)

        #expect(index == "Index.HTML")
    }
}

// MARK: - SettingsManager Tests

@Suite("SettingsManager") @MainActor
struct SettingsManagerTests {
    private let screenConfigurationsKey = "screenConfigurations"
    private let globalSettingsKey = "globalSettings"
    private let aerialsDirectoryBookmarkKey = "AerialsLibrary.DirectoryBookmark"
    private let bookmarksKey = "WallpaperBookmarks.v1"
    private let trustedHostsKey = "TrustedHTMLHosts.v1"

    @Test("Clean all settings clears trusted hosts and saved bookmarks")
    func cleanAllSettingsClearsTrustAndBookmarks() {
        let defaults = UserDefaults.standard
        let keys = [
            screenConfigurationsKey,
            globalSettingsKey,
            aerialsDirectoryBookmarkKey,
            bookmarksKey,
            trustedHostsKey,
        ]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }
        defer { restore(defaults: defaults, values: previousValues, keys: keys) }

        defaults.set(["trusted.example"], forKey: trustedHostsKey)
        defaults.set(Data([0x01, 0x02]), forKey: bookmarksKey)

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)

        #expect(defaults.object(forKey: trustedHostsKey) == nil)
        #expect(defaults.object(forKey: bookmarksKey) == nil)
    }

    @Test("Invalid local HTML bookmark fails configuration validation")
    func invalidLocalHTMLBookmarkFailsValidation() {
        let manager = SettingsManager.shared
        let previousConfigurations = manager.loadConfigurations()
        defer { manager.replaceAllConfigurations(previousConfigurations) }

        let screenID: CGDirectDisplayID = 909_001
        let config = ScreenConfiguration(
            screenID: screenID,
            wallpaper: .html(source: .file(bookmarkData: Data([0x01, 0x02])), config: .default)
        )
        manager.replaceAllConfigurations([config])

        #expect(!manager.validateConfiguration(for: screenID))
    }

    private func restore(defaults: UserDefaults, values: [String: Any], keys: [String]) {
        for key in keys {
            if let value = values[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

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

@Suite("PlainVideoFrameRateCompositionPolicy")
struct PlainVideoFrameRateCompositionPolicyTests {
    @Test("Default 60 FPS keeps plain video on the native playback path")
    func fps60DoesNotUsePlainComposition() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps60,
            videoFrameRate: 120,
            screenRefreshRate: 60
        )

        #expect(limit == nil)
    }

    @Test("Unlimited keeps plain video on the native playback path")
    func unlimitedDoesNotUsePlainComposition() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .unlimited,
            videoFrameRate: 120,
            screenRefreshRate: 60
        )

        #expect(limit == nil)
    }

    @Test("Explicit 30 FPS uses composition when source FPS is higher")
    func fps30UsesCompositionForHighSourceFPS() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps30,
            videoFrameRate: 60,
            screenRefreshRate: 60
        )

        #expect(limit == 30)
    }

    @Test("Explicit 30 FPS skips composition when source FPS is already lower")
    func fps30SkipsCompositionForLowSourceFPS() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps30,
            videoFrameRate: 24,
            screenRefreshRate: 60
        )

        #expect(limit == nil)
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
        config.particleDensity = 2.5

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: data)

        #expect(decoded == config)
    }

    // MARK: particleDensity (regression: previously a dead UI control)

    @Test("Default particleDensity is 1.0")
    func defaultParticleDensity() {
        let config = VideoEffectConfig.default
        #expect(config.particleDensity == 1.0)
    }

    @Test("particleDensity does NOT trigger hasActiveEffect")
    func particleDensityIsNotAColorEffect() {
        var config = VideoEffectConfig.default
        config.particleDensity = 2.5
        // particleDensity is a particle modifier, not a color effect — it must
        // not flip hasActiveEffect or the CIFilter composition path will run
        // unnecessarily and burn CPU/GPU on screens with no real effects.
        #expect(!config.hasActiveEffect)
    }

    @Test("Legacy JSON without particleDensity decodes to 1.0")
    func legacyJsonDefaultsParticleDensityToOne() throws {
        // Old configs persisted before the field existed.
        let legacyJSON = """
        {
            "blurRadius": 0,
            "saturation": 1.0,
            "brightness": 0,
            "warmth": 6500,
            "vignetteIntensity": 0,
            "autoTimeTint": false,
            "weatherReactive": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: legacyJSON)
        #expect(decoded.particleDensity == 1.0)
    }

    @Test("particleDensity round-trip preserves arbitrary value")
    func particleDensityRoundTrip() throws {
        var config = VideoEffectConfig()
        config.particleDensity = 0.3

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: data)

        #expect(decoded.particleDensity == 0.3)
    }
}

// MARK: - ScreenConfiguration Custom Decoder Tests
//
// These tests pin down the backward-compat decoder added during the
// "HTML/shader wallpapers don't survive relaunch" Critical fix.

@Suite("ScreenConfiguration custom decoder")
struct ScreenConfigurationDecoderTests {

    @Test("Legacy JSON with only required fields fills all defaults")
    func legacyJsonMinimalFields() throws {
        // Pre-feature-creep configs only persisted screenID + bookmark.
        let legacyJSON = """
        {
            "screenID": 12345,
            "videoBookmarkData": ""
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: legacyJSON)

        #expect(decoded.screenID == 12345)
        #expect(decoded.playbackSpeed == 1.0)
        #expect(decoded.fitMode == .aspectFill)
        #expect(decoded.frameRateLimit == .fps60)
        #expect(decoded.wallpaperType == .video)
        #expect(decoded.particleEffect == .none)
        #expect(decoded.effectConfig == .default)
        #expect(decoded.htmlContent == nil)
        #expect(decoded.shaderPreset == nil)
        #expect(decoded.scheduleSlots == nil)
        #expect(decoded.playlistBookmarks == nil)
        #expect(decoded.shufflePlaylist == false)
        #expect(decoded.playlistRotationMinutes == nil)
        #expect(decoded.setAsLockScreen == false)
    }

    @Test("HTML wallpaper config round-trips correctly")
    func htmlConfigRoundTrip() throws {
        let url = URL(string: "https://example.com/wallpaper")!
        let original = ScreenConfiguration(
            screenID: 42,
            wallpaper: .html(source: .url(url), config: .default)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.activeWallpaper == .html(source: .url(url), config: .default))
        #expect(decoded.wallpaperType == .html)
        #expect(decoded.htmlContent == "https://example.com/wallpaper")
        #expect(decoded.htmlSource == .url(url))
        #expect(decoded.htmlConfig?.allowJavaScript == true)
        #expect(decoded.htmlConfig?.allowMouseInteraction == false)
        #expect(decoded.htmlConfig?.blockTrackers == true)
        #expect(decoded.screenID == 42)
        #expect(decoded.preferredVideoBookmarkData == nil)
    }

    @Test("HTML wallpaper config persists customised toggles")
    func htmlConfigPersistsCustomToggles() throws {
        let url = URL(string: "https://example.com/wallpaper")!
        let custom = HTMLConfig(
            allowJavaScript: false,
            allowMouseInteraction: true,
            blockTrackers: false,
            customCSS: "body { background: black; }"
        )
        let original = ScreenConfiguration(
            screenID: 11,
            wallpaper: .html(source: .url(url), config: custom)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.htmlConfig == custom)
    }

    @Test("Shader wallpaper config round-trips with preset")
    func shaderConfigRoundTrip() throws {
        let original = ScreenConfiguration(
            screenID: 7,
            wallpaper: .metalShader(.aurora)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.activeWallpaper == .metalShader(.aurora))
        #expect(decoded.wallpaperType == .metalShader)
        #expect(decoded.shaderPreset == .aurora)
    }

    @Test("Legacy non-video config with fake bookmark drops the placeholder bookmark")
    func legacyNonVideoConfigDropsPlaceholderBookmark() throws {
        let legacyJSON = """
        {
            "screenID": 99,
            "videoBookmarkData": "",
            "wallpaperType": "HTML",
            "htmlContent": "https://example.com"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: legacyJSON)

        #expect(decoded.htmlSource == .url(URL(string: "https://example.com")!))
        #expect(decoded.htmlConfig == .default)
        #expect(decoded.preferredVideoBookmarkData == nil)
    }

    @Test("Switching from HTML back to video restores the saved bookmark")
    func switchingBackToVideoRestoresSavedBookmark() {
        let bookmark = Data([0x10, 0x20, 0x30])
        var configuration = ScreenConfiguration(
            screenID: 314,
            videoBookmarkData: bookmark
        )

        configuration.setHTMLWallpaper("https://example.com/live")
        let restored = configuration.activateSavedVideoWallpaper()

        #expect(restored == true)
        #expect(configuration.activeWallpaper == .video(bookmarkData: bookmark))
        #expect(configuration.preferredVideoBookmarkData == bookmark)
    }

    @Test("setAsLockScreen persists across encode/decode")
    func setAsLockScreenRoundTrip() throws {
        let original = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: Data(),
            setAsLockScreen: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.setAsLockScreen == true)
    }

    @Test("particleDensity inside effectConfig survives full round-trip")
    func nestedParticleDensityRoundTrip() throws {
        var effectConfig = VideoEffectConfig()
        effectConfig.particleDensity = 1.7
        let original = ScreenConfiguration(
            screenID: 99,
            videoBookmarkData: Data(),
            particleEffect: .snow,
            effectConfig: effectConfig
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.effectConfig.particleDensity == 1.7)
        #expect(decoded.particleEffect == .snow)
    }

    @Test("Playlist + schedule fields round-trip")
    func playlistAndScheduleRoundTrip() throws {
        let slots = ScheduleSlot.defaultSlots
        let bookmarks = [Data([0x01]), Data([0x02])]
        let original = ScreenConfiguration(
            screenID: 200,
            videoBookmarkData: Data(),
            scheduleSlots: slots,
            playlistBookmarks: bookmarks,
            shufflePlaylist: true,
            playlistRotationMinutes: 15
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.scheduleSlots?.count == slots.count)
        #expect(decoded.playlistBookmarks == bookmarks)
        #expect(decoded.shufflePlaylist == true)
        #expect(decoded.playlistRotationMinutes == 15)
    }

    // MARK: - WallpaperMode Codable migration

    @Test("Legacy JSON without wallpaperMode + scheduleSlots → infers .schedule")
    func legacyInferScheduleMode() throws {
        var config = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: Data([0x01]),
            scheduleSlots: [ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")]
        )
        config.wallpaperMode = .single  // force, then strip below to test inference
        let encoded = try JSONEncoder().encode(config)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "wallpaperMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(decoded.wallpaperMode == .schedule)
    }

    @Test("Legacy JSON without wallpaperMode + playlistBookmarks → infers .playlist")
    func legacyInferPlaylistMode() throws {
        var config = ScreenConfiguration(
            screenID: 2,
            videoBookmarkData: Data([0x01]),
            playlistBookmarks: [Data([0x02])]
        )
        config.wallpaperMode = .single
        let encoded = try JSONEncoder().encode(config)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "wallpaperMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(decoded.wallpaperMode == .playlist)
    }

    @Test("Legacy JSON without wallpaperMode + neither schedule nor playlist → .single")
    func legacyInferSingleMode() throws {
        let config = ScreenConfiguration(
            screenID: 3,
            videoBookmarkData: Data([0x01])
        )
        let encoded = try JSONEncoder().encode(config)
        var dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        dict.removeValue(forKey: "wallpaperMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(decoded.wallpaperMode == .single)
    }

    @Test("Explicit wallpaperMode field round-trips intact")
    func wallpaperModeRoundTrip() throws {
        let bookmark = Data([0x01])
        var config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: bookmark
        )
        config.wallpaperMode = .playlist

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)
        #expect(decoded.wallpaperMode == .playlist)
    }
}

// MARK: - GlobalSettings Custom Decoder Tests

@Suite("GlobalSettings custom decoder")
struct GlobalSettingsDecoderTests {

    @Test("Empty JSON object fills all defaults")
    func emptyJsonDefaults() throws {
        let emptyJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: emptyJSON)

        #expect(decoded.globalPauseOnBattery == false)
        #expect(decoded.preservePlaybackOnLock == false)
        #expect(decoded.startOnLogin == false)
        #expect(decoded.minimumBatteryLevel == nil)
        #expect(decoded.defaultFrameRateLimit == .fps60)
        #expect(decoded.pauseOnFullScreen == true)
    }

    @Test("Partial JSON keeps unspecified fields at default")
    func partialJsonRetainsDefaults() throws {
        let partialJSON = """
        {
            "globalPauseOnBattery": false,
            "minimumBatteryLevel": 0.2
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: partialJSON)

        #expect(decoded.globalPauseOnBattery == false)
        #expect(decoded.minimumBatteryLevel == 0.2)
        // Unspecified fields keep their defaults.
        #expect(decoded.pauseOnFullScreen == true)
        #expect(decoded.defaultFrameRateLimit == .fps60)
    }

    @Test("Legacy JSON carrying `batteryResolutionCap` still decodes")
    func legacyBatteryResolutionCapIgnored() throws {
        // Regression guard: older persisted configs still had the
        // `batteryResolutionCap` key; after removal, unknown keys must not
        // cause decode errors.
        let legacyJSON = """
        {
            "globalPauseOnBattery": true,
            "batteryResolutionCap": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)
        #expect(decoded.globalPauseOnBattery == true)
    }

    @Test("Full round-trip preserves every remaining field")
    func fullRoundTrip() throws {
        let original = GlobalSettings(
            globalPauseOnBattery: false,
            preservePlaybackOnLock: true,
            startOnLogin: true,
            minimumBatteryLevel: 0.15,
            defaultFrameRateLimit: .fps30,
            pauseOnFullScreen: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.globalPauseOnBattery == false)
        #expect(decoded.preservePlaybackOnLock == true)
        #expect(decoded.startOnLogin == true)
        #expect(decoded.minimumBatteryLevel == 0.15)
        #expect(decoded.defaultFrameRateLimit == .fps30)
        #expect(decoded.pauseOnFullScreen == false)
    }
}

// MARK: - ScheduleTimelineBar.segments Tests
//
// Regression coverage for the bug where slots wrapping midnight (e.g. 22→6)
// produced negative segment widths and disappeared from the visualization.

@Suite("ScheduleTimelineBar.segments(for:)")
struct ScheduleTimelineBarSegmentsTests {

    @Test("Normal slot produces a single segment")
    func normalSlotSingleSegment() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        let segments = ScheduleTimelineBar.segments(for: slot)

        #expect(segments.count == 1)
        #expect(segments[0].start == 6)
        #expect(segments[0].end == 12)
    }

    @Test("Wrapping slot (22→6) produces two segments")
    func wrappingSlotTwoSegments() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        let segments = ScheduleTimelineBar.segments(for: slot)

        #expect(segments.count == 2)
        #expect(segments[0].start == 22)
        #expect(segments[0].end == 24)
        #expect(segments[1].start == 0)
        #expect(segments[1].end == 6)
    }

    @Test("Zero-length slot produces no segments")
    func zeroLengthSlotIsEmpty() {
        let slot = ScheduleSlot(startHour: 12, endHour: 12, label: "Empty")
        let segments = ScheduleTimelineBar.segments(for: slot)

        #expect(segments.isEmpty)
    }

    @Test("All default slots produce non-negative widths")
    func defaultSlotsHaveNonNegativeWidths() {
        for slot in ScheduleSlot.defaultSlots {
            let segments = ScheduleTimelineBar.segments(for: slot)
            for segment in segments {
                #expect(segment.end > segment.start, "Segment \(segment) for slot \(slot.label) has non-positive width")
            }
        }
    }

    @Test("Just-after-midnight wrap (1→0) produces two segments")
    func justAfterMidnightWrap() {
        let slot = ScheduleSlot(startHour: 1, endHour: 0, label: "Almost full day")
        let segments = ScheduleTimelineBar.segments(for: slot)

        #expect(segments.count == 2)
        #expect(segments[0].start == 1)
        #expect(segments[0].end == 24)
        #expect(segments[1].start == 0)
        #expect(segments[1].end == 0)
    }
}

// MARK: - FrameRateLimit.resolveCompositionFPS Tests

@Suite("FrameRateLimit.resolveCompositionFPS")
struct ResolveCompositionFPSTests {

    @Test("Unlimited 120fps source on 60Hz screen → 60")
    func unlimited120Source60Screen() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .unlimited,
            videoFrameRate: 120,
            screenRefreshRate: 60
        )
        #expect(fps == 60)
    }

    @Test("Unlimited 120fps source on 120Hz ProMotion → 120")
    func unlimited120SourceProMotion() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .unlimited,
            videoFrameRate: 120,
            screenRefreshRate: 120
        )
        #expect(fps == 120)
    }

    @Test("Unlimited 30fps source on 60Hz → 30 (use native)")
    func unlimited30SourceNative() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .unlimited,
            videoFrameRate: 30,
            screenRefreshRate: 60
        )
        #expect(fps == 30)
    }

    @Test("Unlimited with unknown video fps falls back to screen refresh")
    func unlimitedUnknownVideoFps() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .unlimited,
            videoFrameRate: 0,
            screenRefreshRate: 144
        )
        #expect(fps == 144)
    }

    @Test("Unlimited with everything zero → 60 nominal fallback")
    func unlimitedAllZeroFallback() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .unlimited,
            videoFrameRate: 0,
            screenRefreshRate: 0
        )
        #expect(fps == 60)
    }

    @Test("60 FPS limit on 120fps source on 60Hz → 60")
    func fps60Capped() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .fps60,
            videoFrameRate: 120,
            screenRefreshRate: 60
        )
        #expect(fps == 60)
    }

    @Test("60 FPS limit on 30fps source → use native 30")
    func fps60BelowSourceUsesNative() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .fps60,
            videoFrameRate: 30,
            screenRefreshRate: 60
        )
        #expect(fps == 30)
    }

    @Test("30 FPS limit on 120fps source on 144Hz → 30")
    func fps30AppliedToHighEverything() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .fps30,
            videoFrameRate: 120,
            screenRefreshRate: 144
        )
        #expect(fps == 30)
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
