import SwiftUI
import AppKit

private enum WorkshopProjectActiveAction: Equatable {
    case apply
    case bookmark
}

private enum WorkshopProjectTypeFilter: String, CaseIterable, Identifiable {
    case all
    case video
    case web
    case scene
    case unsupported

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return String(localized: "All", defaultValue: "All", comment: "Workshop library type filter.")
        case .video:
            return WPEType.video.localizedDisplayName
        case .web:
            return WPEType.web.localizedDisplayName
        case .scene:
            return WPEType.scene.localizedDisplayName
        case .unsupported:
            return String(localized: "Unsupported", defaultValue: "Unsupported", comment: "Workshop library type filter.")
        }
    }

    func includes(_ project: WallpaperEngineLibraryScanner.DiscoveredProject) -> Bool {
        switch self {
        case .all:
            return true
        case .video:
            return project.type == .video
        case .web:
            return project.type == .web
        case .scene:
            return project.type == .scene
        case .unsupported:
            return project.type == .application || project.type == .unknown
        }
    }
}

private enum WorkshopProjectSortOrder: String, CaseIterable, Identifiable {
    case recommended
    case name
    case type

    var id: Self { self }

    var title: String {
        switch self {
        case .recommended:
            return String(localized: "Recommended", defaultValue: "Recommended", comment: "Workshop library sort order.")
        case .name:
            return String(localized: "Name", defaultValue: "Name", comment: "Workshop library sort order.")
        case .type:
            return String(localized: "Type", defaultValue: "Type", comment: "Workshop library sort order.")
        }
    }
}

/// Full-screen sheet for browsing and applying projects from the user's Steam Workshop
/// library. Three states: pre-grant (no root bookmark) → scanning → results.
@MainActor
struct WorkshopGalleryView: View {
    let screen: Screen?
    private let fixedTargetScreens: [Screen]
    private let allowsTargetSelection: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(ScreenManager.self) private var screenManager

    @State private var state: PaneState = .needsRoot
    @State private var projects: [WallpaperEngineLibraryScanner.DiscoveredProject] = []
    @State private var activeProjectAction: ActiveProjectAction?
    @State private var errorMessage: String?
    @State private var hasLibraryRoot: Bool = false
    @State private var rootPathSummary: String?
    @State private var selectedTargetScreenID: CGDirectDisplayID?
    @State private var selectedUnsupportedOrigin: WPEOrigin?
    @State private var searchText: String = ""
    @State private var typeFilter: WorkshopProjectTypeFilter = .all
    @State private var pendingDestructive: PendingDestructive?
    @State private var sortOrder: WorkshopProjectSortOrder = .recommended
    @State private var bookmarkStore = BookmarkStore.shared

    private let scanner = WallpaperEngineLibraryScanner()

    init(screen: Screen? = nil, screens: [Screen]? = nil, allowsTargetSelection: Bool = false) {
        self.screen = screen
        self.allowsTargetSelection = allowsTargetSelection
        if let screens {
            fixedTargetScreens = screens
            _selectedTargetScreenID = State(initialValue: screens.first?.id)
        } else if let screen {
            fixedTargetScreens = [screen]
            _selectedTargetScreenID = State(initialValue: screen.id)
        } else {
            fixedTargetScreens = []
            _selectedTargetScreenID = State(initialValue: nil)
        }
    }

    var body: some View {
        DetailPageScaffold(
            showsHeader: hasLibraryRoot,
            header: { header },
            content: { content }
        )
        .onAppear {
            selectInitialTargetIfNeeded()
            updateRootAccessState()
            if hasLibraryRoot {
                Task { await refreshScan() }
            } else {
                state = .needsRoot
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workshopLibraryRootBookmarkDidChange)) { _ in
            // Both handlers mutate @State (hasLibraryRoot / rootPathSummary
            // and the selected-targets set). Defer to next main-actor tick
            // so a notification arriving during SwiftUI's reconcile pass
            // doesn't cascade into "Modifying state during view update".
            Task { @MainActor in updateRootAccessState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in
            Task { @MainActor in selectInitialTargetIfNeeded() }
        }
        .errorAlert("Library Error", message: $errorMessage)
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - Header

    private var header: some View {
        DetailHeaderBar(
            systemImage: "cube.transparent",
            title: {
                Text("Workshop Library")
            },
            metadata: {
                HStack(spacing: DesignTokens.DetailHeader.metadataSpacing) {
                    if state == .scanning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !headerSubtitle.isEmpty {
                        Text(verbatim: headerSubtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(Text(verbatim: headerSubtitle))
                    }
                }
            },
            actions: {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if hasLibraryRoot {
                            if allowsTargetSelection {
                                targetScreenPicker
                            }

                            Button {
                                Task { await refreshScan() }
                            } label: {
                                Label("Rescan", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(WorkshopToolbarButtonStyle())
                            .accessibilityHint(Text("Re-scan the workshop folder for new projects"))
                            .disabled(isBusy)

                            Menu {
                                Button {
                                    presentFolderGrant()
                                } label: {
                                    Label("Change Library Folder...", systemImage: "folder.badge.gearshape")
                                }

                                Button(role: .destructive) {
                                    confirmDisconnectLibraryRoot()
                                } label: {
                                    Label("Forget Library Folder", systemImage: "xmark.circle")
                                }
                            } label: {
                                Label("Library Folder", systemImage: "folder")
                            }
                            .menuStyle(.button)
                            .buttonStyle(WorkshopToolbarButtonStyle(tint: .secondary))
                            .accessibilityHint(Text("Change or forget the selected Steam Workshop folder"))
                            .disabled(isBusy)
                        }

                        if !allowsTargetSelection {
                            Button {
                                dismiss()
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .buttonStyle(WorkshopToolbarButtonStyle(tint: .secondary))
                            .keyboardShortcut(.cancelAction)
                        }
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var targetScreenPicker: some View {
        if !screenManager.screens.isEmpty {
            Picker("Apply to", selection: Binding(
                get: { selectedTargetScreenID ?? screenManager.screens.first?.id },
                set: { selectedTargetScreenID = $0 }
            )) {
                ForEach(screenManager.screens, id: \.id) { screen in
                    Text(verbatim: screen.name).tag(Optional(screen.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 150)
            .help(Text("Choose which display receives Apply actions"))
            .accessibilityLabel(Text("Apply to display"))
            .disabled(isBusy)
        }
    }

    private var headerSubtitle: String {
        switch state {
        case .needsRoot:
            return ""
        case .scanning:
            if let rootPathSummary {
                return String(localized: "Scanning \(rootPathSummary)", comment: "Workshop library scan status. The placeholder is a folder path.")
            }
            return String(localized: "Scanning...", defaultValue: "Scanning...", comment: "Workshop library scan status.")
        case .results:
            if projects.isEmpty, let rootPathSummary {
                return String(localized: "No projects found in \(rootPathSummary)", comment: "Workshop library empty status. The placeholder is a folder path.")
            }
            return String(localized: "\(projects.count) projects · \(actionableCount) can check/apply · \(unsupportedCount) unsupported", comment: "Workshop library summary. Placeholders are total project count, actionable count, and unsupported count.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let selectedUnsupportedOrigin {
            unsupportedDetail(for: selectedUnsupportedOrigin)
        } else {
            switch state {
            case .needsRoot:
                needsRootView
            case .scanning:
                scanningView
            case .results:
                resultsView
            }
        }
    }

    private var needsRootView: some View {
        GuidedLibrarySurface {
            LibraryGuideCard(
                icon: "books.vertical",
                title: "Connect Steam Workshop",
                message: "Choose the Wallpaper Engine folder that contains your subscribed project folders.",
                features: [
                    LibraryGuideFeature(icon: "folder.badge.gearshape", text: "Pick the folder that contains numbered Workshop project folders"),
                    LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "Rescan after Steam downloads or removes subscriptions"),
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Read-only access; projects are prepared only when you apply or bookmark")
                ],
                actionTitle: "Choose Folder...",
                actionSystemImage: "folder.badge.plus",
                action: presentFolderGrant
            )
        }
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning workshop folder…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var resultsView: some View {
        if projects.isEmpty {
            emptyResultsView
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    WorkshopGalleryFilterBar(
                        searchText: $searchText,
                        typeFilter: $typeFilter,
                        sortOrder: $sortOrder,
                        resultCount: visibleProjects.count,
                        totalCount: projects.count,
                        isDisabled: isBusy
                    )

                    if visibleProjects.isEmpty {
                        noFilteredResultsView
                    } else {
                        LazyVGrid(
                            // Fixed-width adaptive columns use extra horizontal
                            // space for more cards without stretching previews.
                            columns: [GridItem(.adaptive(minimum: 160, maximum: 160), spacing: 16)],
                            alignment: .leading,
                            spacing: 16
                        ) {
                            ForEach(visibleProjects) { project in
                                WorkshopGalleryCard(
                                    project: project,
                                    activeAction: activeProjectAction?.action(for: project.id),
                                    isDisabled: isBusy,
                                    canApply: !effectiveTargetScreens.isEmpty,
                                    isBookmarked: isBookmarked(project),
                                    onApply: { Task { await applyOne(project) } },
                                    onToggleBookmark: { Task { await toggleBookmark(project) } }
                                )
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var emptyResultsView: some View {
        GuidedLibrarySurface {
            LibraryGuideCard(
                icon: "folder.badge.questionmark",
                title: "No Workshop projects found",
                message: "The selected folder did not contain Wallpaper Engine project folders. Pick the folder that contains numeric Workshop IDs, then scan again.",
                features: [
                    LibraryGuideFeature(icon: "folder.badge.gearshape", text: "Choose the folder that contains numbered Workshop project folders"),
                    LibraryGuideFeature(icon: "arrow.triangle.2.circlepath", text: "Rescan after Steam finishes downloading subscriptions"),
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Video, Web, and compatible Scene projects can be applied or bookmarked")
                ],
                actionTitle: "Change Folder...",
                actionSystemImage: "folder.badge.gearshape",
                secondaryTitle: "Rescan",
                secondarySystemImage: "arrow.clockwise",
                action: presentFolderGrant,
                secondaryAction: { Task { await refreshScan() } }
            )
        }
    }

    private var noFilteredResultsView: some View {
        VStack(spacing: 12) {
            Label("No matching projects", systemImage: "magnifyingglass")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                clearBrowseFilters()
            } label: {
                Label("Clear Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(GlassCapsuleButtonStyle(tint: .secondary, fontSize: 12, horizontalPadding: 12, verticalPadding: 6))
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func unsupportedDetail(for origin: WPEOrigin) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    selectedUnsupportedOrigin = nil
                } label: {
                    Label("Back to library", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                Spacer()
            }

            WPEFallbackCard(
                origin: origin,
                reason: WPEFallbackCard.reason(for: origin)
            )
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Actions

    private func presentFolderGrant() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.workshopLibraryPrompt(hasLibraryRoot: hasLibraryRoot)
        panel.message = L10n.Panel.workshopProjectsFolderMessage

        if let currentRoot = resolveWorkshopRootURL() {
            panel.directoryURL = currentRoot
        } else if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let lwDir = docs.appendingPathComponent("Live Wallpapers")
            if FileManager.default.fileExists(atPath: lwDir.path) {
                panel.directoryURL = lwDir
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = ResourceUtilities.createBookmark(for: url) else {
            errorMessage = String(localized: "Couldn't create a security-scoped bookmark for that folder.", defaultValue: "Couldn't create a security-scoped bookmark for that folder.", comment: "Workshop library folder grant error.")
            return
        }
        selectedUnsupportedOrigin = nil
        SettingsManager.shared.saveWorkshopLibraryRootBookmark(bookmark)
        updateRootAccessState()
        Task { await refreshScan() }
    }

    private func disconnectLibraryRoot() {
        SettingsManager.shared.clearWorkshopLibraryRootBookmark()
        projects = []
        activeProjectAction = nil
        selectedUnsupportedOrigin = nil
        hasLibraryRoot = false
        rootPathSummary = nil
        state = .needsRoot
    }

    private func confirmDisconnectLibraryRoot() {
        let path = rootPathSummary ?? "your Workshop library folder"
        pendingDestructive = PendingDestructive(.forgetWorkshopLibrary(path: path)) {
            disconnectLibraryRoot()
        }
    }

    private func refreshScan() async {
        updateRootAccessState()
        state = .scanning

        // Resolve persisted state on the main actor before crossing onto the
        // detached scan task. SettingsManager is @MainActor isolated and the
        // scanner itself runs off main.
        guard let bookmark = SettingsManager.shared.loadWorkshopLibraryRootBookmark() else {
            projects = []
            state = .needsRoot
            return
        }
        let alreadyImported = Set(
            SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
        )

        do {
            let discovered = try await scanner.scan(
                rootBookmarkData: bookmark,
                alreadyImportedWorkshopIDs: alreadyImported
            )
            projects = discovered
            state = .results
        } catch WallpaperEngineLibraryScanner.ScanError.rootInaccessible(let detail) {
            // Transient scan failure (security-scoped resource not yet
            // started, directory temporarily missing during a re-launch,
            // etc.). Keep the saved bookmark so the user can retry without
            // re-granting access via the system file panel — only the
            // explicit "Forget Library" destructive action clears the
            // saved bookmark via `disconnectLibraryRoot()`.
            errorMessage = String(
                localized: "Workshop folder is unreachable: \(detail). Try again — your saved access remains.",
                comment: "Workshop library folder access error after a transient scan failure. The placeholder is the system detail. The saved bookmark is preserved so the user can retry."
            )
            projects = []
            state = hasLibraryRoot ? .results : .needsRoot
        } catch {
            errorMessage = error.localizedDescription
            projects = []
            state = hasLibraryRoot ? .results : .needsRoot
        }
    }

    private func applyOne(_ project: WallpaperEngineLibraryScanner.DiscoveredProject) async {
        guard canAttemptAction(project.type) else { return }
        let targets = effectiveTargetScreens
        guard !targets.isEmpty else {
            errorMessage = String(
                localized: "Open a display first, then choose a Workshop wallpaper to apply.",
                defaultValue: "Open a display first, then choose a Workshop wallpaper to apply.",
                comment: "Workshop gallery apply error when there is no target display."
            )
            return
        }

        activeProjectAction = .apply(project.id)
        var failures: [String] = []
        var unsupportedOrigin: WPEOrigin?
        for screen in targets {
            screenManager.clearWPEImportError(for: screen)
            switch await applyForScreenWithLibraryAccess(project, screen: screen) {
            case .applied:
                break
            case .unsupported(let origin):
                unsupportedOrigin = origin
            case .rejected(let failure):
                failures.append(failure)
            }
        }
        activeProjectAction = nil

        if !failures.isEmpty {
            errorMessage = uniqueMessages(failures).joined(separator: "\n")
            await refreshScan()
            return
        }

        if let unsupportedOrigin {
            selectedUnsupportedOrigin = unsupportedOrigin
            await refreshScan()
            return
        }

        await refreshScan()
        if !allowsTargetSelection {
            dismiss()
        }
    }

    private func toggleBookmark(_ project: WallpaperEngineLibraryScanner.DiscoveredProject) async {
        guard canAttemptAction(project.type) else { return }

        if isBookmarked(project) {
            bookmarkStore.removeWPEBookmarks(workshopID: project.workshopID)
            return
        }

        activeProjectAction = .bookmark(project.id)
        let outcome = await prepareWithLibraryAccess(project)
        activeProjectAction = nil

        switch outcome {
        case .ready(let content, let origin):
            if !bookmarkStore.containsWPEBookmark(workshopID: project.workshopID) {
                bookmarkStore.add(
                    label: origin.title,
                    content: content,
                    sourceDisplayName: origin.title,
                    wpeOrigin: origin
                )
            }
        case .unsupported(let origin):
            selectedUnsupportedOrigin = origin
        case .rejected(let reason):
            errorMessage = reason
        }
    }

    private func clearBrowseFilters() {
        searchText = ""
        typeFilter = .all
        sortOrder = .recommended
    }

    /// Re-acquires the persisted root bookmark's security scope for the
    /// duration of one project action. Without this, child URLs handed back by the
    /// scanner are unreachable in a sandboxed build because the scanner's
    /// scope ended when `scan()` returned.
    private func applyForScreenWithLibraryAccess(
        _ project: WallpaperEngineLibraryScanner.DiscoveredProject,
        screen: Screen
    ) async -> ScreenManager.WPEProjectApplyOutcome {
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: project.libraryRootBookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return .rejected(reason: "Workshop folder access expired. Re-grant library access.")
        }

        let didStart = rootURL.startAccessingSecurityScopedResource()
        defer { if didStart { rootURL.stopAccessingSecurityScopedResource() } }

        guard didStart || FileManager.default.fileExists(atPath: project.folderURL.path) else {
            return .rejected(reason: "Workshop folder access denied. Re-grant library access.")
        }

        let outcome = await screenManager.importWallpaperEngineProject(at: project.folderURL, for: screen)
        if let error = screenManager.wpeImportError(for: screen) {
            return .rejected(reason: importErrorMessage(error))
        }
        return outcome
    }

    private func prepareWithLibraryAccess(
        _ project: WallpaperEngineLibraryScanner.DiscoveredProject
    ) async -> ScreenManager.WPEProjectPreparationOutcome {
        var isStale = false
        guard let rootURL = try? URL(
            resolvingBookmarkData: project.libraryRootBookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return .rejected(reason: "Workshop folder access expired. Re-grant library access.")
        }

        let didStart = rootURL.startAccessingSecurityScopedResource()
        defer { if didStart { rootURL.stopAccessingSecurityScopedResource() } }

        guard didStart || FileManager.default.fileExists(atPath: project.folderURL.path) else {
            return .rejected(reason: "Workshop folder access denied. Re-grant library access.")
        }

        return await screenManager.prepareWallpaperEngineProject(at: project.folderURL)
    }

    // MARK: - Helpers

    private var visibleProjects: [WallpaperEngineLibraryScanner.DiscoveredProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = projects.filter { project in
            typeFilter.includes(project) && matchesSearch(project, query: query)
        }

        switch sortOrder {
        case .recommended:
            return filtered
        case .name:
            return filtered.sorted { compareByTitleThenID($0, $1) }
        case .type:
            return filtered.sorted {
                let lhsRank = typeSortRank($0.type)
                let rhsRank = typeSortRank($1.type)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return compareByTitleThenID($0, $1)
            }
        }
    }

    private var actionableCount: Int {
        projects.filter { canAttemptAction($0.type) }.count
    }

    private var unsupportedCount: Int {
        projects.filter { !canAttemptAction($0.type) }.count
    }

    private var isBusy: Bool {
        activeProjectAction != nil
    }

    private var effectiveTargetScreens: [Screen] {
        if allowsTargetSelection {
            guard let selectedTargetScreenID,
                  let selected = screenManager.screens.first(where: { $0.id == selectedTargetScreenID }) else {
                return []
            }
            return [selected]
        }
        return fixedTargetScreens
    }

    private func canAttemptAction(_ type: WPEType) -> Bool {
        switch type {
        case .video, .web, .scene: return true
        case .application, .unknown: return false
        }
    }

    private func matchesSearch(
        _ project: WallpaperEngineLibraryScanner.DiscoveredProject,
        query: String
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return project.title.localizedCaseInsensitiveContains(query)
            || project.workshopID.localizedCaseInsensitiveContains(query)
            || project.type.localizedDisplayName.localizedCaseInsensitiveContains(query)
    }

    private func compareByTitleThenID(
        _ lhs: WallpaperEngineLibraryScanner.DiscoveredProject,
        _ rhs: WallpaperEngineLibraryScanner.DiscoveredProject
    ) -> Bool {
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.workshopID.localizedCaseInsensitiveCompare(rhs.workshopID) == .orderedAscending
    }

    private func typeSortRank(_ type: WPEType) -> Int {
        switch type {
        case .video:        return 0
        case .web:          return 1
        case .scene:        return 2
        case .application:  return 3
        case .unknown:      return 4
        }
    }

    private func isBookmarked(_ project: WallpaperEngineLibraryScanner.DiscoveredProject) -> Bool {
        bookmarkStore.containsWPEBookmark(workshopID: project.workshopID)
    }

    private func selectInitialTargetIfNeeded() {
        guard allowsTargetSelection else { return }
        if let selectedTargetScreenID,
           screenManager.screens.contains(where: { $0.id == selectedTargetScreenID }) {
            return
        }
        selectedTargetScreenID = screenManager.screens.first?.id
    }

    private func updateRootAccessState() {
        guard SettingsManager.shared.loadWorkshopLibraryRootBookmark() != nil else {
            hasLibraryRoot = false
            rootPathSummary = nil
            return
        }

        hasLibraryRoot = true
        rootPathSummary = resolveWorkshopRootURL()?.path
    }

    private func resolveWorkshopRootURL() -> URL? {
        guard let bookmark = SettingsManager.shared.loadWorkshopLibraryRootBookmark() else {
            return nil
        }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private func importErrorMessage(_ error: AppError) -> String {
        let description = error.localizedDescription
        guard let suggestion = error.recoverySuggestion, !suggestion.isEmpty else {
            return description
        }
        return "\(description)\n\(suggestion)"
    }

    private func uniqueMessages(_ messages: [String]) -> [String] {
        var result: [String] = []
        for message in messages where !result.contains(message) {
            result.append(message)
        }
        return result
    }

    private enum PaneState: Equatable {
        case needsRoot
        case scanning
        case results
    }

    private enum ActiveProjectAction: Equatable {
        case apply(String)
        case bookmark(String)

        func action(for projectID: String) -> WorkshopProjectActiveAction? {
            switch self {
            case .apply(let activeID) where activeID == projectID:
                return .apply
            case .bookmark(let activeID) where activeID == projectID:
                return .bookmark
            default:
                return nil
            }
        }
    }
}

// MARK: - Browse Controls

private struct WorkshopGalleryFilterBar: View {
    @Binding var searchText: String
    @Binding var typeFilter: WorkshopProjectTypeFilter
    @Binding var sortOrder: WorkshopProjectSortOrder

    let resultCount: Int
    let totalCount: Int
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            searchField

            Picker("Type", selection: $typeFilter) {
                ForEach(WorkshopProjectTypeFilter.allCases) { filter in
                    Text(verbatim: filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 118)
            .help(Text("Filter by project type"))

            Picker("Sort", selection: $sortOrder) {
                ForEach(WorkshopProjectSortOrder.allCases) { order in
                    Text(verbatim: order.title).tag(order)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 132)
            .help(Text("Sort workshop projects"))

            Spacer(minLength: 10)

            Text(verbatim: "\(resultCount)/\(totalCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help(Text("Visible projects"))
        }
        .disabled(isDisabled)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search Workshop", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

// MARK: - Card

private struct WorkshopGalleryCard: View {
    let project: WallpaperEngineLibraryScanner.DiscoveredProject
    let activeAction: WorkshopProjectActiveAction?
    let isDisabled: Bool
    let canApply: Bool
    let isBookmarked: Bool
    let onApply: () -> Void
    let onToggleBookmark: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Square preview occupies the full 160pt card width (160×160).
            WPEPreviewView(
                imageURL: project.previewURL,
                securityScopedBookmarkData: project.libraryRootBookmarkData
            )
                .wpeCardPreviewClip()
                .overlay(alignment: .topTrailing) {
                    typeBadge
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: project.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(cardAccessibilityLabel)

                actionButton
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .wpeProjectCardChrome(isHovering: isHovering)
        .onHover { isHovering = $0 }
        // Deliberately NOT .accessibilityElement(children: .combine) — that
        // would swallow the inner action buttons. Letting SwiftUI infer the
        // tree keeps the action reachable for VoiceOver users.
    }

    @ViewBuilder
    private var typeBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(typeColor).frame(width: 6, height: 6)
            Text(verbatim: typeLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Apple HIG: prefer semantic materials for image overlays.
        // Locking colorScheme to dark keeps the label legible regardless of
        // the underlying preview brightness.
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch project.type {
        case .video, .web, .scene:
            VStack(alignment: .leading, spacing: 6) {
                if project.type == .scene {
                    sceneStatusLabel
                }

                HStack(spacing: 6) {
                    Button(action: onApply) {
                        Label(primaryTitle, systemImage: primarySystemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 9, verticalPadding: 5))
                    .disabled(isDisabled || activeAction != nil || !canApply)
                    .help(canApply ? Text(primaryTitle) : Text("Choose a display before applying"))

                    Button(action: onToggleBookmark) {
                        Image(systemName: bookmarkSystemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(
                        tint: isBookmarked ? .yellow : .secondary,
                        fontSize: 11,
                        horizontalPadding: 8,
                        verticalPadding: 5
                    ))
                    .disabled(isDisabled || activeAction != nil)
                    .help(isBookmarked ? Text("Remove Bookmark") : Text("Add Bookmark"))
                    .accessibilityLabel(Text(isBookmarked ? "Remove Bookmark" : "Add Bookmark"))
                }
            }
        case .application:
            Label("Executable · skipped", systemImage: "lock.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .unknown:
            Label("Unknown type", systemImage: "questionmark.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var sceneStatusLabel: some View {
        Label(sceneStatusText, systemImage: sceneStatusSystemImage)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(sceneStatusColor)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryTitle: String {
        switch activeAction {
        case .apply:
            return "Applying..."
        case .bookmark:
            return project.type == .scene ? "Check & Apply" : "Apply"
        case nil:
            return project.type == .scene ? "Check & Apply" : "Apply"
        }
    }

    private var primarySystemImage: String {
        switch activeAction {
        case .apply:
            return "hourglass"
        case .bookmark, nil:
            return project.type == .scene ? "checkmark.circle" : "play.fill"
        }
    }

    private var bookmarkSystemImage: String {
        if activeAction == .bookmark { return "hourglass" }
        return isBookmarked ? "bookmark.fill" : "bookmark"
    }

    private var sceneStatusText: String {
        if project.requiresWindowsPlugin {
            return "Scene · won't run"
        }
        if !project.hasScenePackage {
            return "Scene · check needed"
        }
        if !project.dependencyWorkshopIDs.isEmpty {
            return "Scene · check needed"
        }
        return "Scene · may work"
    }

    private var sceneStatusSystemImage: String {
        if project.requiresWindowsPlugin { return "xmark.octagon.fill" }
        if project.hasScenePackage { return "questionmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }

    private var sceneStatusColor: Color {
        if project.requiresWindowsPlugin { return .red }
        if project.hasScenePackage { return .orange }
        return .yellow
    }

    private var typeLabel: String {
        project.type == .unknown ? "?" : project.type.localizedDisplayName
    }

    private var cardAccessibilityLabel: Text {
        if isBookmarked {
            return Text("\(project.title), \(typeLabel) wallpaper, already bookmarked", comment: "Workshop gallery card a11y label for an already-bookmarked project. Placeholders are project title and project type.")
        }
        return Text("\(project.title), \(typeLabel) wallpaper", comment: "Workshop gallery card a11y label. Placeholders are project title and project type.")
    }

    private var typeColor: Color {
        switch project.type {
        case .video:        return .blue
        case .web:          return .green
        case .scene:        return .orange
        case .application:  return .red
        case .unknown:      return .gray
        }
    }
}

private struct WorkshopToolbarButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var fontSize: CGFloat = 13
    var horizontalPadding: CGFloat = 15
    var verticalPadding: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            tint: tint,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let fontSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let effectiveTint = isEnabled ? tint : Color.secondary
            configuration.label
                .font(.system(size: fontSize, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(effectiveTint)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(minHeight: 34)
                .glassEffect(
                    .regular.tint(effectiveTint.opacity(isEnabled ? 0.16 : 0.06)).interactive(),
                    in: .capsule
                )
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.46)
        }
    }
}
