import Testing
import Foundation
import CoreGraphics
import LiveWallpaperCore
import SwiftUI
@testable import LiveWallpaper

@Suite("Settings window layout")
struct SettingsWindowLayoutTests {
    @Test("Settings window defaults fit the minimum composed layout")
    func settingsWindowDefaultsFitMinimumComposedLayout() {
        let resizableInspectorMainFloor: CGFloat = 360

        #expect(SettingsWindowMetrics.defaultContentSize.width >= SettingsWindowMetrics.minimumContentSize.width)
        #expect(SettingsWindowMetrics.defaultContentSize.height >= SettingsWindowMetrics.minimumContentSize.height)
        #expect(SettingsWindowMetrics.minimumContentSize.width >= SettingsWindowMetrics.sidebarColumnMaxWidth + DesignTokens.LibraryPage.minWidth)
        #expect(SettingsWindowMetrics.minimumContentSize.height >= DesignTokens.LibraryPage.minHeight)
        #expect(SettingsWindowMetrics.sidebarColumnMaxWidth == SettingsWindowMetrics.sidebarColumnWidth * 1.2)
        #expect(DesignTokens.LibraryPage.minWidth >= DesignTokens.Inspector.minWidth)
        #expect(DesignTokens.LibraryPage.minWidth >= resizableInspectorMainFloor + DesignTokens.Inspector.maxWidth)
        #expect(DesignTokens.Inspector.idealWidth >= DesignTokens.Inspector.minWidth)
        #expect(DesignTokens.Inspector.idealWidth <= DesignTokens.Inspector.maxWidth)
        #expect(DesignTokens.Inspector.maxWidth >= 384)
    }

    @Test("Preview area caps media previews to the available low-height viewport")
    func previewAreaCapsMediaPreviewsToAvailableHeight() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScreenDetailPreviewArea.swift")

        #expect(source.contains("GeometryReader"))
        #expect(source.contains("cappedPreviewHeight"))
        #expect(source.contains("videoPreviewReservedHeight"))
        #expect(source.contains("htmlSourceReservedHeight"))
    }

    @Test("HTML preview area uses the same non-scrolling left layout as video and scene")
    func htmlPreviewAreaUsesNonScrollingLeftLayout() throws {
        let source = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScreenDetailPreviewArea.swift")
        let htmlContent = try #require(Self.slice(
            source,
            from: "private var htmlContent",
            to: "/// A Wallpaper Engine web project's shipped preview asset"
        ))

        #expect(!htmlContent.contains("ScrollView"))
        #expect(htmlContent.contains("HTMLPreviewSection("))
        #expect(htmlContent.contains("HTMLSourceSection("))
        #expect(htmlContent.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
    }

    @Test("HTML rendering diagnostics live inside the preview overlay")
    func htmlRenderingDiagnosticsLiveInsidePreviewOverlay() throws {
        let inspectorPanel = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScreenDetailInspectorPanel.swift")
        let previewSection = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/HTMLPreviewSection.swift")

        #expect(!inspectorPanel.contains("HTMLRenderingDiagnosticsInspector("))
        #expect(previewSection.contains("HTMLRenderingDiagnosticsOverlay("))
        #expect(previewSection.contains("HTMLRenderingDiagnostics(screen: screen"))
        #expect(previewSection.contains(".thumbnailBadgeGlass()"))
        #expect(previewSection.contains("alignment: .topLeading"))
        #expect(previewSection.contains("alignment: .bottomLeading"))
        #expect(previewSection.contains("diagnosticTag(\"Measurement\""))
        #expect(previewSection.contains("diagnosticTag(\"Points\""))
        #expect(previewSection.contains("diagnosticTag(\"Backing\""))
        #expect(previewSection.contains("diagnosticTag(\"Scale\""))
        #expect(previewSection.contains("diagnosticTag(\"Viewport\""))
        #expect(previewSection.contains("diagnosticTag(\"DPR\""))
        #expect(previewSection.contains("diagnosticTag(\"Mode\""))
    }

    @Test("HTML source controls use a compact row below preview")
    func htmlSourceControlsUseCompactRowBelowPreview() throws {
        let previewArea = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScreenDetailPreviewArea.swift")
        let sourceSection = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/HTMLSourceSection.swift")

        #expect(previewArea.contains("private let htmlSourceReservedHeight: CGFloat = 88"))
        #expect(previewArea.contains("VStack(spacing: 8)"))
        #expect(sourceSection.contains("HStack(alignment: .center, spacing: 10)"))
        #expect(sourceSection.contains(".frame(width: 108)"))
        #expect(sourceSection.contains(".padding(.vertical, 6)"))
    }

    @Test("HTML preview area uses uniform outer padding")
    func htmlPreviewAreaUsesUniformOuterPadding() throws {
        let previewArea = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScreenDetailPreviewArea.swift")
        let htmlContent = try #require(Self.slice(
            previewArea,
            from: "private var htmlContent",
            to: "private func cappedPreviewHeight"
        ))

        #expect(htmlContent.contains("verticalPadding: 24"))
        #expect(htmlContent.contains(".padding(24)"))
        #expect(!htmlContent.contains(".padding(.vertical, 14)"))
    }

    @Test("HTML preview prefers live web snapshots before static fallbacks")
    func htmlPreviewPrefersLiveWebSnapshots() throws {
        let previewSection = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/HTMLPreviewSection.swift")
        let runtimeSession = try Self.readSourceFile("LiveWallpaper/Runtime/Session/WallpaperRuntimeSession.swift")
        let htmlView = try Self.readSourceFile("LiveWallpaper/VideoPlayback/HTMLWallpaperView.swift")

        #expect(previewSection.contains("captureLiveHTMLSnapshot"))
        #expect(previewSection.contains("let liveImage = await captureLiveHTMLSnapshot()"))
        #expect(previewSection.contains("} else if let wpePreviewURL {"))
        #expect(runtimeSession.contains("func captureLiveHTMLSnapshot() async -> NSImage?"))
        #expect(htmlView.contains("func captureLivePreviewSnapshot"))
        #expect(htmlView.contains("webView.takeSnapshot"))
    }

    @Test("Inspector resize drag clamps at minimum before drag-to-close")
    func inspectorResizeDragClampsAtMinimumBeforeDragToClose() throws {
        let split = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ResizableInspectorSplit.swift")
        let handle = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/InspectorResizeHandle.swift")

        #expect(split.contains("private var dragLowerBound: CGFloat { minWidth }"))
        #expect(split.contains("minWidth: minWidth"))
        #expect(!split.contains("return min(max(CGFloat(liveWidth), dragLowerBound), maxWidth)"))
        #expect(handle.contains("private func rawCandidate"))
        #expect(handle.contains("if armed(for: rawCandidate)"))
    }

    @Test("HTML wallpaper type is presented to users as Web")
    func htmlWallpaperTypeIsPresentedAsWeb() throws {
        let wallpaperType = try Self.readSourceFile("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Schema/WallpaperType.swift")
        let emptyStateGuide = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/EmptyStateGuideView.swift")

        #expect(wallpaperType.contains("case .html: return \"Web\""))
        #expect(!wallpaperType.contains("case .html: return \"HTML\""))
        #expect(emptyStateGuide.contains("title: \"Web\""))
        #expect(emptyStateGuide.contains("accessibilityLabel: \"Web wallpaper type\""))
    }

    @Test("Scene scaling includes Center without adding it to video preview controls")
    func sceneScalingIncludesCenterWithoutAddingItToVideoPreviewControls() throws {
        #expect(VideoFitMode.videoModes == [.aspectFill, .aspectFit, .stretch])
        #expect(VideoFitMode.sceneModes == [.aspectFill, .aspectFit, .stretch, .center])

        let previewArea = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/ScreenDetailPreviewArea.swift")
        let playbackInspector = try Self.readSourceFile("LiveWallpaper/Views/ScreenDetail/CommonPlaybackInspector.swift")

        #expect(previewArea.contains("ForEach(VideoFitMode.videoModes)"))
        #expect(playbackInspector.contains("ForEach(VideoFitMode.sceneModes)"))
    }

    private static func readSourceFile(_ relativePath: String) throws -> String {
        try RepositoryRoot.source(relativePath)
    }

    private static func slice(_ source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source[startRange.lowerBound...].range(of: end) else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
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

    @Test("Sandbox entitlements allow read-write user-selected files")
    func sandboxEntitlementsAllowReadWriteUserSelectedFiles() throws {
        let data = try RepositoryRoot.data("LiveWallpaper/LiveWallpaper.entitlements")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        // read-write is required so `.fileExporter` (configuration backup) can
        // write to a user-chosen destination; individual wallpaper bookmarks
        // still narrow themselves to read via `securityScopeAllowOnlyReadAccess`.
        #expect(plist["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(plist["com.apple.security.files.user-selected.read-only"] == nil)
    }

    @Test("Supported video URL detection accepts video files and rejects unrelated drops")
    func supportedVideoURLDetectionRejectsUnrelatedFiles() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let mp4URL = folder.appendingPathComponent("clip.mp4")
        let textURL = folder.appendingPathComponent("notes.txt")
        try Data([0x00]).write(to: mp4URL)
        try Data("not a video".utf8).write(to: textURL)

        #expect(ResourceUtilities.isSupportedVideoURL(mp4URL))
        #expect(!ResourceUtilities.isSupportedVideoURL(textURL))
    }

    @Test("HTML resource detection accepts HTML files and folders only")
    func htmlResourceDetectionAcceptsHTMLFilesAndFoldersOnly() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let htmlURL = folder.appendingPathComponent("index.html")
        let textURL = folder.appendingPathComponent("notes.txt")
        try Data("<!doctype html>".utf8).write(to: htmlURL)
        try Data("not html".utf8).write(to: textURL)

        #expect(ResourceUtilities.isSupportedHTMLResourceURL(folder))
        #expect(ResourceUtilities.isSupportedHTMLResourceURL(htmlURL))
        #expect(!ResourceUtilities.isSupportedHTMLResourceURL(textURL))
    }

    @Test("Picked HTML file stays a file source instead of switching UI to folder mode")
    func pickedHTMLFileStaysFileSource() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let htmlURL = folder.appendingPathComponent("index.html")
        try Data("<!doctype html><title>QA</title>".utf8).write(to: htmlURL)

        let source = try #require(ResourceUtilities.htmlSourceFromPickedFile(htmlURL))

        guard case .file = source else {
            Issue.record("Picked HTML file should remain a file source; got \(source)")
            return
        }
    }

    @Test("Video bookmark creation falls back to an app-owned copy when scoped bookmark creation fails")
    func videoBookmarkCreationFallsBackToAppOwnedCopy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let appSupportRoot = root.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("bg.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: sourceURL)

        let bookmark = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )

        let importedRoot = appSupportRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let importedDirectories = try fileManager.contentsOfDirectory(
            at: importedRoot,
            includingPropertiesForKeys: nil
        )
        let hashDirectoryName = try #require(importedDirectories.first?.lastPathComponent)
        let reconstructedCopiedURL = importedRoot
            .appendingPathComponent(hashDirectoryName, isDirectory: true)
            .appendingPathComponent("bg.mp4", isDirectory: false)

        #expect(bookmark == Data(reconstructedCopiedURL.path(percentEncoded: false).utf8))
        #expect(fileManager.fileExists(atPath: reconstructedCopiedURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: reconstructedCopiedURL) == Data([0x00, 0x01, 0x02]))
    }

    @Test("Video fallback reuses the app-owned copy for the same source")
    func videoBookmarkCreationReusesAppOwnedCopyForSameSource() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let appSupportRoot = root.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("bg.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: sourceURL)

        let firstBookmark = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )
        let secondBookmark = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )

        let importedRoot = appSupportRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let importedDirectories = try fileManager.contentsOfDirectory(
            at: importedRoot,
            includingPropertiesForKeys: nil
        )

        #expect(firstBookmark == secondBookmark)
        #expect(importedDirectories.count == 1)
        #expect(fileManager.fileExists(
            atPath: importedDirectories[0].appendingPathComponent("bg.mp4").path(percentEncoded: false)
        ))
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

    @Test("App-owned non-scoped video bookmark passes configuration validation")
    func appOwnedNonScopedVideoBookmarkPassesConfigurationValidation() throws {
        let manager = SettingsManager.shared
        let previousConfigurations = manager.loadConfigurations()
        defer { manager.replaceAllConfigurations(previousConfigurations) }

        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-local-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try Data([0x00, 0x01]).write(to: videoURL)
        let bookmark = try videoURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let screenID: CGDirectDisplayID = 909_002
        manager.replaceAllConfigurations([
            ScreenConfiguration(screenID: screenID, videoBookmarkData: bookmark)
        ])

        #expect(manager.validateConfiguration(for: screenID))
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

    // naturalDefault: the picker and the runtime agree on the type-
    // appropriate baseline. Scene defaults to 30 (WPE parity); video /
    // html / metalShader keep 60 (native pass-through, no extra cost).
    @Test("naturalDefault returns fps30 for scene wallpapers (WPE parity)")
    func naturalDefaultForScene() {
        #expect(FrameRateLimit.naturalDefault(for: .scene) == .fps30)
    }

    @Test("naturalDefault returns fps60 for non-scene wallpapers")
    func naturalDefaultForOthers() {
        #expect(FrameRateLimit.naturalDefault(for: .video) == .fps60)
        #expect(FrameRateLimit.naturalDefault(for: .html) == .fps60)
        #expect(FrameRateLimit.naturalDefault(for: .metalShader) == .fps60)
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

    @Test("fps15 caps a 60fps source to 15")
    func fps15CapsHighSourceFPS() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps15,
            videoFrameRate: 60,
            screenRefreshRate: 60
        )

        #expect(limit == 15)
    }

    @Test("fps24 caps a 60fps source to 24")
    func fps24CapsHighSourceFPS() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps24,
            videoFrameRate: 60,
            screenRefreshRate: 60
        )

        #expect(limit == 24)
    }

    @Test("fps24 skips composition when source is already 24fps cinema")
    func fps24SkipsForCinematicSource() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps24,
            videoFrameRate: 24,
            screenRefreshRate: 60
        )

        #expect(limit == nil)
    }

    @Test("fps15 skips composition when source is 10fps timelapse")
    func fps15SkipsForSlowSource() {
        let limit = PlainVideoFrameRateCompositionPolicy.compositionLimit(
            frameRateLimit: .fps15,
            videoFrameRate: 10,
            screenRefreshRate: 60
        )

        #expect(limit == nil)
    }
}

@Suite("ParticleEffect Codable")
struct ParticleEffectCodableTests {
    @Test("Unknown raw value decodes to .none for compatibility")
    func unknownRawValueDecodesToNone() throws {
        let data = try JSONEncoder().encode("Lightning")
        let decoded = try JSONDecoder().decode(ParticleEffect.self, from: data)
        #expect(decoded == .none)
    }

    @Test("Known raw values still round-trip")
    func knownRawValuesRoundTrip() throws {
        for effect in ParticleEffect.allCases {
            let data = try JSONEncoder().encode(effect)
            let decoded = try JSONDecoder().decode(ParticleEffect.self, from: data)
            #expect(decoded == effect)
        }
    }
}

@Suite("FrameRateLimit.enforcesCompositionCap")
struct FrameRateLimitEnforcesCompositionCapTests {
    @Test("Low-FPS caps force composition")
    func lowFpsCapsForce() {
        #expect(FrameRateLimit.fps15.enforcesCompositionCap)
        #expect(FrameRateLimit.fps24.enforcesCompositionCap)
        #expect(FrameRateLimit.fps30.enforcesCompositionCap)
    }

    @Test("fps60 and Unlimited stay on the native pass-through")
    func passThroughCapsSkipComposition() {
        #expect(!FrameRateLimit.fps60.enforcesCompositionCap)
        #expect(!FrameRateLimit.unlimited.enforcesCompositionCap)
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
        #expect(!config.hasActiveEffect)
    }

    @Test("Legacy JSON without particleDensity decodes to 1.0")
    func legacyJsonDefaultsParticleDensityToOne() throws {
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
        #expect(decoded.videoBookmarkData == nil)
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
        #expect(decoded.videoBookmarkData == nil)
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
        #expect(configuration.videoBookmarkData == bookmark)
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
        let config = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: Data([0x01]),
            scheduleSlots: [ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")]
        )
        let encoded = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict.removeValue(forKey: "wallpaperMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(decoded.wallpaperMode == .schedule)
    }

    @Test("Legacy JSON without wallpaperMode (no schedule) → defaults to .playlist")
    func legacyInferDefaultPlaylistMode() throws {
        let config = ScreenConfiguration(
            screenID: 3,
            videoBookmarkData: Data([0x01])
        )
        let encoded = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict.removeValue(forKey: "wallpaperMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(decoded.wallpaperMode == .playlist)
    }

    @Test("Legacy `single` value in stored wallpaperMode rolls forward to .playlist")
    func legacySingleStringRollsToPlaylist() throws {
        let config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: Data([0x01])
        )
        let encoded = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict["wallpaperMode"] = "single"
        let mutated = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: mutated)
        #expect(decoded.wallpaperMode == .playlist)
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
        #expect(decoded.pauseOnFullScreen == true)
    }

    @Test("Legacy JSON carrying the removed `minimumBatteryLevel` key still decodes")
    func legacyMinimumBatteryLevelIgnored() throws {
        let legacyJSON = """
        {
            "globalPauseOnBattery": true,
            "minimumBatteryLevel": 0.2
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)

        #expect(decoded.globalPauseOnBattery == true)
        #expect(decoded.pauseOnFullScreen == true)
    }

    @Test("Legacy JSON carrying `batteryResolutionCap` still decodes")
    func legacyBatteryResolutionCapIgnored() throws {
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
            pauseOnFullScreen: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.globalPauseOnBattery == false)
        #expect(decoded.preservePlaybackOnLock == true)
        #expect(decoded.startOnLogin == true)
        #expect(decoded.pauseOnFullScreen == false)
    }

    @Test("Legacy JSON carrying retired defaultFrameRateLimit decodes without error")
    func legacyDefaultFrameRateLimitIgnored() throws {
        // Older builds persisted this field; ensure existing settings files
        // still load after the field was removed.
        let legacyJSON = """
        {
            "defaultFrameRateLimit": 60,
            "pauseOnFullScreen": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)
        #expect(decoded.pauseOnFullScreen == true)
    }
}

// MARK: - ScheduleSlot.timelineSegments Tests
//
// Regression coverage for the bug where slots wrapping midnight (e.g. 22→6)
// produced negative segment widths and disappeared from the visualization.

@Suite("ScheduleSlot.timelineSegments()")
struct ScheduleSlotTimelineSegmentsTests {

    @Test("Normal slot produces a single segment")
    func normalSlotSingleSegment() {
        let slot = ScheduleSlot(startHour: 6, endHour: 12, label: "Morning")
        let segments = slot.timelineSegments()

        #expect(segments.count == 1)
        #expect(segments[0].start == 6)
        #expect(segments[0].end == 12)
        #expect(segments[0].wraps == false)
    }

    @Test("Wrapping slot (22→6) produces two segments")
    func wrappingSlotTwoSegments() {
        let slot = ScheduleSlot(startHour: 22, endHour: 6, label: "Night")
        let segments = slot.timelineSegments()

        #expect(segments.count == 2)
        #expect(segments[0].start == 22)
        #expect(segments[0].end == 24)
        #expect(segments[0].wraps == true)
        #expect(segments[1].start == 0)
        #expect(segments[1].end == 6)
        #expect(segments[1].wraps == true)
    }

    @Test("Zero-length slot produces no segments")
    func zeroLengthSlotIsEmpty() {
        let slot = ScheduleSlot(startHour: 12, endHour: 12, label: "Empty")
        #expect(slot.timelineSegments().isEmpty)
    }

    @Test("All default slots produce non-negative widths")
    func defaultSlotsHaveNonNegativeWidths() {
        for slot in ScheduleSlot.defaultSlots {
            for segment in slot.timelineSegments() {
                #expect(segment.end > segment.start, "Segment for slot \(slot.label) has non-positive width")
            }
        }
    }

    @Test("Slot ending at next-day midnight (1→0) collapses to a single segment")
    func slotEndingAtNextDayMidnight() {
        // `endHour == 0` with `startHour > 0` semantically wraps to the next
        // day's midnight — the [0, 0) second half has zero width and is
        // dropped so the editor never has to filter empty segments.
        let slot = ScheduleSlot(startHour: 1, endHour: 0, label: "Almost full day")
        let segments = slot.timelineSegments()

        #expect(segments.count == 1)
        #expect(segments[0].start == 1)
        #expect(segments[0].end == 24)
        #expect(segments[0].wraps == true)
    }

    @Test("wraps property matches start > end semantics")
    func wrapsFlagMatchesStartGtEnd() {
        #expect(ScheduleSlot(startHour: 6, endHour: 12, label: "x").wraps == false)
        #expect(ScheduleSlot(startHour: 12, endHour: 6, label: "x").wraps == true)
        #expect(ScheduleSlot(startHour: 22, endHour: 0, label: "x").wraps == true)
        // Zero-length is non-wrapping by the start > end definition.
        #expect(ScheduleSlot(startHour: 12, endHour: 12, label: "x").wraps == false)
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

    @Test("24 FPS limit on 60fps source → 24 (cinematic cap)")
    func fps24AppliedToHighSource() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .fps24,
            videoFrameRate: 60,
            screenRefreshRate: 60
        )
        #expect(fps == 24)
    }

    @Test("15 FPS limit on 30fps source → 15 (deep battery saver)")
    func fps15AppliedToModerateSource() {
        let fps = FrameRateLimit.resolveCompositionFPS(
            limit: .fps15,
            videoFrameRate: 30,
            screenRefreshRate: 60
        )
        #expect(fps == 15)
    }

    @Test("Legacy raw values 15 and 24 decode to their cases")
    func legacyRawValuesDecodeToNewCases() throws {
        let data15 = try JSONEncoder().encode(15)
        let decoded15 = try JSONDecoder().decode(FrameRateLimit.self, from: data15)
        #expect(decoded15 == .fps15)

        let data24 = try JSONEncoder().encode(24)
        let decoded24 = try JSONDecoder().decode(FrameRateLimit.self, from: data24)
        #expect(decoded24 == .fps24)
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
