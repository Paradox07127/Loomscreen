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

    @Test("Screen detail hides playback inspector while the selected display has no configurable surface")
    func screenDetailHidesInspectorForGuideOnlyEmptyState() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(
            !source.contains("selectedWallpaperType == .video || selectedWallpaperType == .html"),
            "The inspector should not appear just because the segmented picker is on Video or HTML; a guide-only empty state has no controls to apply."
        )
        #expect(
            source.contains("hasConfigurableWallpaperSurface"),
            "ScreenDetailView should gate the inspector on an existing configuration, runtime session, or preview source."
        )
        #expect(
            source.contains("shouldShowGuideEmptyState") && source.contains("!shouldShowGuideEmptyState"),
            "The guide empty state should explicitly suppress the right inspector column."
        )
    }

    @Test("Screen detail guide-only state hides wallpaper toolbar actions")
    func screenDetailGuideHidesWallpaperToolbarActions() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(source.contains("private var showsHeaderWallpaperActions"))
        #expect(source.contains("hasConfigurableWallpaperSurface && !shouldShowGuideEmptyState"))
        #expect(source.contains("if showsHeaderWallpaperActions {"))
        #expect(
            !source.contains("if selectedWallpaperType == .video {\n                    HStack(spacing: 8)"),
            "The header wallpaper actions must not be keyed only off selectedWallpaperType; the guide already owns first-pick actions."
        )
    }

    @Test("Screen detail clear action is generic across wallpaper types")
    func screenDetailClearActionIsGenericAcrossWallpaperTypes() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(source.contains("Clear Current Wallpaper"))
        #expect(source.contains("performClearWallpaper()"))
        #expect(source.contains("screenManager.clearWallpaperForScreen(screen)"))
        #expect(!source.contains("Clear Wallpaper Video"))
        #expect(!source.contains("Clear Video"))
        #expect(!source.contains("performClearVideo"))
        #expect(!source.contains("clearVideo()"))
        #expect(!source.contains("Remove wallpaper video"))
        #expect(!source.contains("Clear video"))
        #expect(
            source.contains("Only removes the current wallpaper from this display"),
            "The destructive confirmation must say it does not delete source files or library items."
        )
    }

    @Test("Initial wallpaper type guide keeps compact vertical rhythm")
    func initialWallpaperTypeGuideKeepsCompactVerticalRhythm() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/EmptyStateGuideView.swift")

        #expect(source.contains("VStack(spacing: 16)"))
        #expect(source.contains(".padding(.vertical, 20)"))
        #expect(source.contains("VStack(spacing: 6)"))
        #expect(source.contains(".font(.system(size: 30"))
        #expect(source.contains(".frame(minHeight: 152"))
        #expect(!source.contains("VStack(spacing: 24)"))
        #expect(!source.contains(".padding(.vertical, 32)"))
        #expect(!source.contains(".frame(minHeight: 168"))
    }

    @Test("Screen detail keeps wallpaper type picker in the centered titlebar toolbar")
    func screenDetailKeepsWallpaperTypePickerInCenteredToolbar() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(source.contains("ToolbarItem(placement: .principal)"))
        #expect(source.contains("wallpaperTypeToolbar"))
        #expect(
            !source.contains("wallpaperTypePicker\n                        .layoutPriority(1)"),
            "Wallpaper type should not live in the display-info header actions where it competes with screen metadata."
        )
    }

    @Test("Runtime status labels describe motion state, not wallpaper type")
    func runtimeStatusLabelsDescribeMotionStateOnly() throws {
        let screenDetailSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")
        let contentSource = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")

        #expect(
            screenDetailSource.contains("\"Playing\"") && screenDetailSource.contains("\"Paused\""),
            "The detail header status beside the display should describe whether the wallpaper is moving."
        )
        #expect(
            contentSource.contains("\"Playing\"") && contentSource.contains("\"Paused\""),
            "The sidebar display status should stay wallpaper-type agnostic."
        )
        #expect(
            !screenDetailSource.contains("Video Playing") && !contentSource.contains("Video Playing"),
            "Running-state labels should not include the wallpaper type."
        )
        #expect(
            !screenDetailSource.contains("HTML Active") && !screenDetailSource.contains("Shader Active"),
            "The detail header status should describe activity, not wallpaper type."
        )
        #expect(
            !contentSource.contains("return \"HTML\"") && !contentSource.contains("return \"Shader\""),
            "The sidebar display status should describe activity, not wallpaper type."
        )
    }

    @Test("Main app chrome avoids under-page background in light mode")
    func mainAppChromeAvoidsUnderPageBackgroundInLightMode() throws {
        let chromeFiles = [
            "LiveWallpaper/Views/ContentView.swift",
            "LiveWallpaper/Views/DetailPageScaffold.swift",
            "LiveWallpaper/Views/GeneralSettingsView.swift",
            "LiveWallpaper/Views/ScreenDetailView.swift",
            "LiveWallpaper/Views/SettingsFormChrome.swift"
        ]
        let combinedSource = try chromeFiles
            .map(sourceText(for:))
            .joined(separator: "\n")
        let tokensSource = try sourceText(for: "LiveWallpaper/Views/Styles/DesignTokens.swift")

        #expect(
            !combinedSource.contains("underPageBackgroundColor"),
            "NSColor.underPageBackgroundColor resolves to a dark gray Aqua color and should not be used for the settings window's primary chrome."
        )
        #expect(tokensSource.contains("windowBackgroundColor"))
        #expect(combinedSource.contains("DesignTokens.Colors.pageBackground"))
    }

    @Test("Hand managed app windows use system window background")
    func handManagedAppWindowsUseSystemWindowBackground() throws {
        let source = try sourceText(for: "LiveWallpaper/LiveWallpaperApp.swift")

        #expect(source.components(separatedBy: "window.backgroundColor = .windowBackgroundColor").count >= 3)
    }

    @Test("Playback speed segments expose the full segment as the hit target")
    func playbackSpeedSegmentsExposeFullHitTarget() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/ScreenDetailControls.swift")

        #expect(source.contains(".contentShape(RoundedRectangle(cornerRadius:"))
        #expect(source.contains(".frame(minWidth:"))
    }

    @Test("Shared destructive tint also applies an interactive liquid glass surface")
    func destructiveTintAppliesInteractiveLiquidGlass() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/Styles/DestructiveControlTint.swift")

        #expect(source.contains(".glassEffect("))
        #expect(source.contains(".interactive()"))
        #expect(source.contains("Color.red.opacity"))
    }

    @Test("Destructive and reset controls use red tint outside confirmation dialogs")
    func destructiveControlsUseSharedRedTint() throws {
        let destructiveControlFiles = [
            "LiveWallpaper/Views/ScreenDetailView.swift",
            "LiveWallpaper/Views/BookmarksLibraryView.swift",
            "LiveWallpaper/Views/BookmarksPopover.swift",
            "LiveWallpaper/Views/ScheduleSection.swift",
            "LiveWallpaper/Views/WPECacheManagementView.swift",
            "LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift",
            "LiveWallpaper/Views/ScreenDetail/ColorAdjustmentsView.swift",
            "LiveWallpaper/Views/AppleAerialsLibraryView.swift",
            "LiveWallpaper/Views/Settings/WeatherLocationSettingsView.swift",
        ]

        for path in destructiveControlFiles {
            let source = try sourceText(for: path)
            #expect(source.contains(".destructiveControlTint()"), "\(path) should use the shared destructive tint modifier.")
        }

        let shortcuts = try sourceText(for: "LiveWallpaper/Views/Settings/ShortcutsSettingsView.swift")
        #expect(shortcuts.contains("Button(\"Clear\", role: .destructive)"))
        #expect(shortcuts.contains("Button(\"Reset to Default\", role: .destructive)"))
    }

    @Test("Manual weather search uses non-deprecated MapKit location API")
    func manualWeatherSearchUsesMapItemLocation() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/Settings/WeatherLocationSettingsView.swift")

        #expect(source.contains("item.location.coordinate"))
        #expect(!source.contains("item.placemark.coordinate"))
    }

    @Test("Preview poster loads are keyed by video bookmark so settings changes do not rebuild media")
    func previewPosterLoadsAreKeyedByBookmark() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(source.contains("@State private var lastPreviewPosterBookmarkData"))
        #expect(source.contains("lastPreviewPosterBookmarkData == bookmarkData"))
        #expect(source.contains("previewController.posterImage != nil || previewController.isLoading"))
    }

    @Test("Views read prepared bookmark display names instead of resolving bookmarks while rendering")
    func viewsReadPreparedBookmarkDisplayNames() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsRoot = projectRoot.appendingPathComponent("LiveWallpaper/Views")
        let files = FileManager.default.enumerator(
            at: viewsRoot,
            includingPropertiesForKeys: nil
        )?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let offenders = try files.compactMap { url -> String? in
            let source = try String(contentsOf: url, encoding: .utf8)
            guard source.contains("ResourceUtilities.resolveBookmarkName") else { return nil }
            return url.path.replacingOccurrences(of: projectRoot.path + "/", with: "")
        }

        #expect(
            offenders.isEmpty,
            "Bookmark names should be resolved on import/config changes, not from SwiftUI render paths: \(offenders.joined(separator: ", "))"
        )
    }

    @Test("Bookmark display name ownership lives in ScreenManager instead of a TTL resolver cache")
    func bookmarkDisplayNameOwnershipLivesInScreenManager() throws {
        let screenManagerSource = try sourceText(for: "LiveWallpaper/ScreenManager.swift")
        let resourceUtilitiesSource = try sourceText(for: "LiveWallpaper/ResourceUtilities.swift")

        #expect(screenManagerSource.contains("bookmarkDisplayNames"))
        #expect(screenManagerSource.contains("recordBookmarkDisplayName"))
        #expect(screenManagerSource.contains("primeBookmarkDisplayNames"))
        #expect(!resourceUtilitiesSource.contains("bookmarkNameCacheTTL"))
    }

    @Test("Bookmark last-path-component resolution is centralized")
    func bookmarkLastPathComponentResolutionIsCentralized() throws {
        let htmlSource = try sourceText(for: "LiveWallpaper/Models/HTMLSource.swift")
        let resourceUtilities = try sourceText(for: "LiveWallpaper/ResourceUtilities.swift")
        let resolver = try sourceText(for: "LiveWallpaper/Infrastructure/BookmarkNameResolver.swift")

        #expect(htmlSource.contains("BookmarkNameResolver.lastPathComponent"))
        #expect(resourceUtilities.contains("BookmarkNameResolver.lastPathComponent"))
        #expect(!htmlSource.contains("resolvingBookmarkData"))
        #expect(resolver.contains("ResourceUtilities.resolveBookmark"))
    }

    @Test("RAM scope segmented control is shared")
    func ramScopeSegmentedControlIsShared() throws {
        let systemMonitor = try sourceText(for: "LiveWallpaper/Views/SystemMonitorView.swift")
        let menuBarContent = try sourceText(for: "LiveWallpaper/Views/MenuBarContent.swift")
        let sharedControl = try sourceText(for: "LiveWallpaper/Views/RAMScopePicker.swift")

        #expect(!systemMonitor.contains("private func ramScopeButton"))
        #expect(!menuBarContent.contains("private func ramScopeButton"))
        #expect(systemMonitor.contains("RAMScopePicker("))
        #expect(menuBarContent.contains("RAMScopePicker("))
        #expect(sharedControl.contains("private func scopeButton"))
    }

    @Test("Settings forms use shared chrome")
    func settingsFormsUseSharedChrome() throws {
        let weather = try sourceText(for: "LiveWallpaper/Views/Settings/WeatherLocationSettingsView.swift")
        let shortcuts = try sourceText(for: "LiveWallpaper/Views/Settings/ShortcutsSettingsView.swift")
        let cache = try sourceText(for: "LiveWallpaper/Views/WPECacheManagementView.swift")
        let sharedChrome = try sourceText(for: "LiveWallpaper/Views/SettingsFormChrome.swift")

        #expect(weather.contains(".settingsFormChrome("))
        #expect(shortcuts.contains(".settingsFormChrome("))
        #expect(cache.contains(".settingsFormChrome("))
        #expect(!weather.contains(".contentMargins(.horizontal, DesignTokens.Settings.formHorizontalMargin"))
        #expect(!shortcuts.contains(".contentMargins(.horizontal, DesignTokens.Settings.formHorizontalMargin"))
        #expect(sharedChrome.contains("DesignTokens.Settings.formHorizontalMargin"))
    }

    @Test("Wallpaper Engine folder import panel is shared")
    func wallpaperEngineFolderImportPanelIsShared() throws {
        let sceneSection = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WPESceneSection.swift")
        let onboarding = try sourceText(for: "LiveWallpaper/Views/Onboarding/OnboardingStepFirstWallpaper.swift")
        let picker = try sourceText(for: "LiveWallpaper/Infrastructure/WPEFolderPicker.swift")

        #expect(sceneSection.contains("WPEFolderPicker.chooseImportFolder()"))
        #expect(onboarding.contains("WPEFolderPicker.chooseImportFolder()"))
        #expect(picker.contains("panel.canChooseDirectories = true"))
        #expect(picker.contains("Live Wallpapers"))
        #expect(picker.contains("L10n.Panel.importProject"))
    }

    @Test("HTML source kind picker is shared")
    func htmlSourceKindPickerIsShared() throws {
        let screenDetail = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/HTMLSourceSection.swift")
        let onboarding = try sourceText(for: "LiveWallpaper/Views/Onboarding/OnboardingStepFirstWallpaper.swift")
        let picker = try sourceText(for: "LiveWallpaper/Views/HTMLSourceKindPicker.swift")

        #expect(screenDetail.contains("HTMLSourceKindPicker(selection: $selectedKind)"))
        #expect(onboarding.contains("HTMLSourceKindPicker(selection: $selectedKind)"))
        #expect(picker.contains("Picker(\"Source\", selection: $selection)"))
        #expect(picker.contains("HTMLSourceKind.allCases"))
    }

    @Test("Wallpaper Engine cards share preview and hover chrome")
    func wallpaperEngineCardsSharePreviewAndHoverChrome() throws {
        let historyRow = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WPEHistoryRow.swift")
        let workshop = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")
        let chrome = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WPEProjectCardChrome.swift")

        #expect(historyRow.contains(".wpeCardPreviewClip()"))
        #expect(workshop.contains(".wpeCardPreviewClip()"))
        #expect(historyRow.contains(".wpeProjectCardChrome(isHovering: isHovering)"))
        #expect(workshop.contains(".wpeProjectCardChrome(isHovering: isHovering)"))
        #expect(chrome.contains("UnevenRoundedRectangle("))
        #expect(chrome.contains(".glassEffect(.regular.interactive()"))
    }

    @Test("Content view auto-selects a single connected display")
    func contentViewAutoSelectsSingleDisplay() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")

        #expect(source.contains("selectDefaultDisplayIfNeeded()"))
        #expect(source.contains("screenManager.screens.count == 1"))
        #expect(source.contains("selectedNavigation = .screen(screen.id)"))
        #expect(source.contains(".onReceive(NotificationCenter.default.publisher(for: .screensRefreshed))"))
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
            "The hover state needs a centered affordance that communicates horizontal resizing."
        )
        #expect(
            source.contains(".overlay(alignment: .leading)"),
            "The resize control should be attached to the inspector edge instead of occupying its own split-view column."
        )
        #expect(
            source.contains("InspectorResizeHandle.hitAreaWidth"),
            "The attached handle still needs a stable pointer hit area."
        )
        #expect(
            source.contains("private let restingHandleWidth") && source.contains("private let activeHandleWidth"),
            "The resize affordance should rest as a slim capsule and expand on hover or drag."
        )
        #expect(
            !source.contains("Rectangle()\n                .fill(Color(NSColor.separatorColor)"),
            "Do not draw an always-visible standalone divider line beside the inspector."
        )
    }

    @Test("Playlist rows prioritize filename over secondary controls")
    func playlistRowsPrioritizeFilenameOverSecondaryControls() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/PlaylistSection.swift")

        #expect(source.contains(".layoutPriority(1)"), "Playlist filenames need first claim on row width.")
        #expect(source.contains(".help(Text(verbatim: entry.name))"), "Truncated filenames should still be discoverable via tooltip.")
        #expect(!source.contains("Button(action: onRemove)"), "A hidden remove button still consumes row width; removal belongs in the menu.")
        #expect(source.contains("Image(systemName: \"star.fill\")"), "Primary state should use a compact icon badge in narrow inspectors.")
    }

    @Test("Sidebar always exposes Workshop library entry")
    func sidebarAlwaysExposesWorkshopLibraryEntry() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")

        #expect(source.contains("Label(\"Workshop Library\", systemImage: \"cube.transparent\")"))
        #expect(source.contains("NavigationLink(value: Navigation.workshop)"))
        #expect(!source.contains("Label(\"Steam Workshop\", systemImage: \"cube.transparent\")"))
        #expect(!source.contains("workshopLibraryAvailable"))
        #expect(!source.contains("refreshWorkshopAvailability"))
    }

    @Test("Sidebar dashboard keeps fixed layout animation with original visual spacing")
    func sidebarDashboardKeepsFixedLayoutAnimationWithOriginalVisualSpacing() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/SystemMonitorView.swift")
        let scopePickerSource = try sourceText(for: "LiveWallpaper/Views/RAMScopePicker.swift")
        let composedSource = source + "\n" + scopePickerSource

        #expect(!source.contains("LazyVGrid(columns: [GridItem(.flexible()"))
        #expect(source.contains("private var gaugeGrid: some View"))
        #expect(source.contains("HStack(spacing: 8)"))
        #expect(source.contains(".padding(.horizontal, 6)"))
        #expect(source.contains(".padding(.vertical, 8)"))
        #expect(composedSource.contains(".font(.system(size: 10"))
        #expect(composedSource.contains(".padding(.vertical, 3)"))
        #expect(source.contains("lineWidth: 6"))
        #expect(source.contains(".font(.system(size: 14, weight: .bold))"))
        #expect(source.contains(".frame(width: 54, height: 54)"))
        #expect(!source.contains(".frame(width: 48, height: 48)"))
        #expect(source.contains("private var displayedPercent: Int"))
        #expect(source.contains("value: displayedPercent"))
    }

    @Test("Sidebar section headers use shared spacing tokens")
    func sidebarSectionHeadersUseSharedSpacingTokens() throws {
        let contentSource = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")
        let tokenSource = try sourceText(for: "LiveWallpaper/Views/Styles/DesignTokens.swift")

        #expect(contentSource.contains("SidebarSectionHeader("))
        #expect(contentSource.contains("bottomPadding: DesignTokens.Sidebar.displayHeaderBottomPadding"))
        #expect(tokenSource.contains("static let displayHeaderBottomPadding"))
        #expect(tokenSource.contains("static let sectionHeaderSpacing"))
    }

    @Test("Settings window uses native split-view chrome")
    func settingsWindowUsesNativeSplitViewChrome() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")

        #expect(source.contains("NavigationSplitView"))
        #expect(source.contains(".navigationSplitViewStyle(.balanced)"))
        #expect(source.contains(".navigationSplitViewColumnWidth("))
        #expect(!source.contains("@State private var isSidebarVisible = true"))
        #expect(!source.contains("transaction.disablesAnimations = true"))
        #expect(!source.contains(".ignoresSafeArea(.container, edges: .top)"))
        #expect(!source.contains(".safeAreaInset(edge: .top"))
        #expect(!source.contains("SettingsTopChrome("))
    }

    @Test("Settings window keeps Xcode-style native titlebar chrome")
    func settingsWindowKeepsXcodeStyleNativeTitlebarChrome() throws {
        let appSource = try sourceText(for: "LiveWallpaper/LiveWallpaperApp.swift")
        let contentSource = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")
        let screenDetailSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(appSource.contains(".fullSizeContentView"))
        #expect(appSource.contains("window.titlebarAppearsTransparent = true"))
        #expect(!appSource.contains("window.isMovableByWindowBackground = true"))
        #expect(appSource.components(separatedBy: "window.isMovableByWindowBackground = false").count >= 3)
        #expect(contentSource.contains("NavigationSplitView {"))
        #expect(contentSource.contains("ToolbarItem(placement: .navigation)"))
        #expect(contentSource.contains("Image(systemName: \"gearshape\")"))
        #expect(!appSource.contains("window.toolbarStyle = .unified"))
        #expect(!appSource.contains("window.toolbar = makeSettingsToolbar()"))
        #expect(!appSource.contains("extension AppDelegate: NSToolbarDelegate"))
        #expect(!contentSource.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
        #expect(!contentSource.contains("SettingsSidebarChrome("))
        #expect(!contentSource.contains("CollapsedSettingsSidebarChrome("))
        #expect(!contentSource.contains(".toolbarVisibility(.hidden, for: .windowToolbar)"))
        #expect(screenDetailSource.contains("private var wallpaperTypePicker: some View"))
        #expect(screenDetailSource.contains("private var applyToAllButton: some View"))
        #expect(!screenDetailSource.contains("@ToolbarContentBuilder"))
        #expect(!screenDetailSource.contains(".toolbar { screenDetailToolbar }"))
        #expect(!contentSource.contains(".safeAreaInset(edge: .top"))
        #expect(!contentSource.contains("struct SettingsTopChrome"))
    }

    @Test("Video and HTML pickers share ResourceUtilities type lists")
    func pickersShareResourceUtilitiesTypeLists() throws {
        let pickerFiles = [
            "LiveWallpaper/Views/ContentView.swift",
            "LiveWallpaper/Views/ScreenDetailView.swift",
            "LiveWallpaper/Views/Onboarding/OnboardingStepFirstWallpaper.swift",
            "LiveWallpaper/Views/PlaylistSection.swift",
            "LiveWallpaper/Views/ScheduleSection.swift",
            "LiveWallpaper/Views/ScreenDetail/HTMLSourceSection.swift",
        ]
        let combinedSource = try pickerFiles.map(sourceText(for:)).joined(separator: "\n")

        #expect(!combinedSource.contains("allowedContentTypes = [.movie"))
        #expect(!combinedSource.contains("allowedContentTypes = [UTType.html]"))
        #expect(combinedSource.contains("ResourceUtilities.supportedVideoContentTypes"))
        #expect(combinedSource.contains("ResourceUtilities.supportedHTMLContentTypes"))
    }

    @Test("Drop handlers reject unsupported files before creating video bookmarks")
    func dropHandlersRejectUnsupportedFilesBeforeBookmarking() throws {
        let contentSource = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")
        let screenDetailSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")

        #expect(contentSource.contains("ResourceUtilities.isSupportedVideoURL(videoURL)"))
        #expect(screenDetailSource.contains("ResourceUtilities.isSupportedVideoURL(droppedURL)"))
        #expect(screenDetailSource.contains("Choose a video file, HTML file, or folder."))
    }

    @Test("Detail navigation keeps the original transition format")
    func detailNavigationKeepsOriginalTransitionFormat() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")
        let start = try #require(source.range(of: "struct DetailContent: View"))
        let end = try #require(source.range(of: "// MARK: - Empty State View"))
        let detailSource = String(source[start.lowerBound..<end.lowerBound])

        #expect(detailSource.contains(".transition(.opacity)"))
        #expect(detailSource.contains(".animation(.snappy(duration: 0.3), value: selection)"))
    }

    @Test("Collapsible sections rely on one explicit expansion animation")
    func collapsibleSectionsRelyOnOneExplicitExpansionAnimation() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/CollapsibleSection.swift")

        #expect(source.contains("withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.28)))"))
        #expect(!source.contains(".animation(reduceMotion ? nil : .snappy(duration: 0.28), value: isExpanded)"))
    }

    @Test("System monitor first sample is not synchronous during sidebar appearance")
    func systemMonitorFirstSampleIsNotSynchronousDuringSidebarAppearance() throws {
        let source = try sourceText(for: "LiveWallpaper/SystemMonitor.swift")
        let start = try #require(source.range(of: "func startMonitoring()"))
        let end = try #require(source.range(of: "func stopMonitoring()"))
        let startMonitoring = String(source[start.lowerBound..<end.lowerBound])
        let sleep = try #require(startMonitoring.range(of: "try await Task.sleep(for: initialSampleDelay)"))
        let sample = try #require(startMonitoring.range(of: "self.updateResourceUsage()"))

        #expect(startMonitoring.contains("let initialSampleDelay = MonitoringStartPolicy.initialSampleDelay"))
        #expect(startMonitoring.contains("try await Task.sleep(for: initialSampleDelay)"))
        #expect(sleep.lowerBound < sample.lowerBound)
        #expect(!startMonitoring.hasSuffix("updateResourceUsage()\n    }\n\n    "))
    }

    @Test("Workshop and Aerials initial states omit inline headers")
    func workshopAndAerialsInitialStatesOmitInlineHeaders() throws {
        let workshopSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")
        let aerialsSource = try sourceText(for: "LiveWallpaper/Views/AppleAerialsLibraryView.swift")

        #expect(workshopSource.contains("DetailPageScaffold(\n            showsHeader: hasLibraryRoot"))
        #expect(!workshopSource.contains("case .needsRoot:\n            return \"Choose your Steam Wallpaper Engine folder to discover projects\""))
        #expect(aerialsSource.contains("DetailPageScaffold(\n            showsHeader: library.isAuthorized"))
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

    @Test("Detail pages share header and scaffold primitives")
    func detailPagesShareHeaderAndScaffoldPrimitives() throws {
        let headerSource = try sourceText(for: "LiveWallpaper/Views/DetailPageScaffold.swift")
        let screenSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetailView.swift")
        let bookmarksSource = try sourceText(for: "LiveWallpaper/Views/BookmarksLibraryView.swift")
        let aerialsSource = try sourceText(for: "LiveWallpaper/Views/AppleAerialsLibraryView.swift")
        let workshopSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")

        #expect(headerSource.contains("struct DetailPageScaffold"))
        #expect(headerSource.contains("struct DetailHeaderBar"))
        #expect(headerSource.contains("struct GuidedLibrarySurface"))
        #expect(screenSource.contains("DetailHeaderBar("))
        #expect(bookmarksSource.contains("DetailPageScaffold("))
        #expect(bookmarksSource.contains("DetailHeaderBar("))
        #expect(aerialsSource.contains("DetailPageScaffold("))
        #expect(aerialsSource.contains("GuidedLibrarySurface"))
        #expect(workshopSource.contains("DetailPageScaffold("))
        #expect(workshopSource.contains("GuidedLibrarySurface"))
    }

    @Test("Library pages share the detail canvas background")
    func libraryPagesShareTheDetailCanvasBackground() throws {
        let contentSource = try sourceText(for: "LiveWallpaper/Views/ContentView.swift")
        let workshopSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")
        let scaffoldSource = try sourceText(for: "LiveWallpaper/Views/DetailPageScaffold.swift")

        #expect(contentSource.contains(".background(DesignTokens.Colors.pageBackground)"))
        #expect(workshopSource.contains("DetailPageScaffold("))
        #expect(scaffoldSource.contains(".background(DesignTokens.Colors.pageBackground)"))
        #expect(!workshopSource.contains(".background(Color(NSColor.windowBackgroundColor))"))
    }

    @Test("General settings keeps native forms while using compact page chrome")
    func generalSettingsKeepsNativeFormsWhileUsingCompactPageChrome() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/GeneralSettingsView.swift")
        let chromeSource = try sourceText(for: "LiveWallpaper/Views/SettingsFormChrome.swift")
        let composedSource = source + "\n" + chromeSource

        #expect(source.contains("TabView {"))
        #expect(source.contains("Form {"))
        #expect(source.contains("private func settingsForm"))
        #expect(composedSource.contains(".formStyle(.grouped)"))
        #expect(composedSource.contains(".scrollContentBackground(.hidden)"))
        #expect(composedSource.contains("DesignTokens.Colors.pageBackground"))
        #expect(source.contains("private var troubleshootingActions"))
        #expect(source.contains("private func settingsActionButton"))
        #expect(source.contains("HStack(spacing: DesignTokens.Settings.actionGridSpacing)"))
    }

    @Test("General settings absorbs thin power page and right sizes language picker")
    func generalSettingsAbsorbsThinPowerPageAndRightSizesLanguagePicker() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/GeneralSettingsView.swift")

        #expect(!source.contains(".tabItem { Label(\"Power\""))
        #expect(!source.contains("private var powerTab"))
        #expect(source.contains("private var powerSavingSection"))
        #expect(source.contains("private var batteryThresholdSection"))
        #expect(source.contains("powerSavingSection"))
        #expect(source.contains("batteryThresholdSection"))
        #expect(source.contains("private var languagePicker"))
        #expect(source.contains(".fixedSize()"))
        #expect(!source.contains(".frame(width: 180)"))
    }

    @Test("Apple Aerials guide states do not keep the legacy card copy")
    func appleAerialsGuideStatesDoNotKeepLegacyCardCopy() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/AppleAerialsLibraryView.swift")

        #expect(source.contains("private func scanErrorView(message: String) -> some View {\n        GuidedLibrarySurface"))
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

    @Test("Workshop gallery applies selected compatible projects to the current screen")
    func workshopGalleryAppliesSelectedCompatibleProjectsToCurrentScreen() throws {
        let workshopSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")
        let sceneSectionSource = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WPESceneSection.swift")

        #expect(workshopSource.contains("let screen: Screen"))
        #expect(sceneSectionSource.contains("WorkshopGalleryView(screen: screen)"))
        #expect(workshopSource.contains("screenManager.importWallpaperEngineProject(at: project.folderURL, for: screen)"))
        #expect(workshopSource.contains("dismiss()"))
        #expect(!workshopSource.contains("return await screenManager.importWPEToLibrary(at: project.folderURL)"))
    }

    @Test("Workshop gallery cards expose apply actions for already imported compatible projects")
    func workshopGalleryCardsExposeApplyActionsForAlreadyImportedCompatibleProjects() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")

        #expect(source.contains("project.importedAlready ? \"Apply\" : \"Import & Apply\""))
        #expect(!source.contains("Label(\"In Library\""))
    }

    @Test("Workshop gallery header uses capsule glass controls and omits bulk import")
    func workshopGalleryHeaderUsesCapsuleGlassControlsAndOmitsBulkImport() throws {
        let source = try sourceText(for: "LiveWallpaper/Views/ScreenDetail/WorkshopGalleryView.swift")

        #expect(source.contains("GlassEffectContainer"))
        #expect(source.contains("WorkshopToolbarButtonStyle"))
        #expect(!source.contains("Import All Compatible"))
        #expect(!source.contains("bulkImportCompatible"))
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

@Suite("Release readiness safeguards")
struct ReleaseReadinessSafeguardsTests {
    @Test("Static audit rejects broad NSObject NSSecureCoding decode allow-lists")
    func staticAuditRejectsBroadNSObjectDecodeAllowLists() throws {
        let auditSource = try sourceText(for: "scripts/audit.sh")

        #expect(auditSource.contains("insecure-secure-coding.txt"))
        #expect(auditSource.contains("NSKeyedUnarchiver"))
        #expect(auditSource.contains("NSObject"))
        #expect(auditSource.contains("ERROR: Insecure NSSecureCoding allow-list"))
    }

    @Test("Formal release check can require Developer ID signing identity")
    func formalReleaseCheckCanRequireDeveloperIDSigningIdentity() throws {
        let releaseCheckSource = try sourceText(for: "scripts/release_candidate_check.sh")

        #expect(releaseCheckSource.contains("REQUIRE_DEVELOPER_ID"))
        #expect(releaseCheckSource.contains("ERROR: No Developer ID Application signing identity found"))
        #expect(releaseCheckSource.contains("exit 1"))
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

    @Test("Sandbox entitlements allow read-only user-selected bookmarks")
    func sandboxEntitlementsAllowReadOnlyUserSelectedBookmarks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testsDirectory.deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("LiveWallpaper/LiveWallpaper.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        #expect(plist["com.apple.security.files.user-selected.read-only"] as? Bool == true)
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
        let copiedURL = try #require(importedDirectories.first?.appendingPathComponent("bg.mp4"))

        #expect(bookmark == Data(copiedURL.path(percentEncoded: false).utf8))
        #expect(fileManager.fileExists(atPath: copiedURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: copiedURL) == Data([0x00, 0x01, 0x02]))
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
