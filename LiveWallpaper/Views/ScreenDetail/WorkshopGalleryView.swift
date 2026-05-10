import SwiftUI
import AppKit

/// Full-screen sheet for browsing + bulk-importing the user's Steam Workshop
/// library. Three states: pre-grant (no root bookmark) → scanning → results.
@MainActor
struct WorkshopGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ScreenManager.self) private var screenManager

    @State private var state: PaneState = .needsRoot
    @State private var projects: [WallpaperEngineLibraryScanner.DiscoveredProject] = []
    @State private var bulkImportInProgress: Bool = false
    @State private var bulkImportProgress: (current: Int, total: Int) = (0, 0)
    @State private var errorMessage: String?
    @State private var hasLibraryRoot: Bool = false
    @State private var rootPathSummary: String?

    private let scanner = WallpaperEngineLibraryScanner()

    var body: some View {
        DetailPageScaffold(
            showsHeader: hasLibraryRoot,
            header: { header },
            content: { content }
        )
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            updateRootAccessState()
            if hasLibraryRoot {
                Task { await refreshScan() }
            } else {
                state = .needsRoot
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .workshopLibraryRootBookmarkDidChange)) { _ in
            updateRootAccessState()
        }
        .alert("Library Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
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
                HStack(spacing: 8) {
                    if hasLibraryRoot {
                        Button {
                            Task { await refreshScan() }
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .accessibilityHint(Text("Re-scan the workshop folder for new projects"))
                        .disabled(bulkImportInProgress)

                        Button {
                            presentFolderGrant()
                        } label: {
                            Label("Change Folder", systemImage: "folder.badge.gearshape")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .accessibilityHint(Text("Choose a different Steam Workshop folder"))
                        .disabled(bulkImportInProgress)

                        Button {
                            disconnectLibraryRoot()
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.glass)
                        .destructiveControlTint()
                        .controlSize(.regular)
                        .help(Text("Disconnect Workshop library"))
                        .accessibilityLabel(Text("Disconnect Workshop library"))
                        .accessibilityHint(Text("Forgets the selected Steam Workshop folder so you can choose again"))
                        .disabled(bulkImportInProgress)
                    }

                    if case .results = state, !projects.isEmpty {
                        Button {
                            Task { await bulkImportCompatible() }
                        } label: {
                            if bulkImportInProgress {
                                Label("Importing \(bulkImportProgress.current)/\(bulkImportProgress.total)", systemImage: "square.and.arrow.down.fill")
                            } else {
                                Label("Import All Compatible", systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.regular)
                        .disabled(bulkImportInProgress || compatibleCount == 0)
                        .accessibilityHint(Text("Imports every Video and Web project not already in your library"))
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
                }
            }
        )
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
            return String(localized: "\(projects.count) projects · \(compatibleCount) compatible · \(unsupportedCount) preview-only", comment: "Workshop library summary. Placeholders are total project count, compatible count, and preview-only count.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .needsRoot:
            needsRootView
        case .scanning:
            scanningView
        case .results:
            resultsView
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
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Read-only access; imported copies stay managed by LiveWallpaper")
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
                LazyVGrid(
                    // Fixed-width columns so the 1:1 square preview area is
                    // identical across cards regardless of window width.
                    columns: Array(repeating: GridItem(.fixed(160), spacing: 16), count: 4),
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(projects) { project in
                        WorkshopGalleryCard(
                            project: project,
                            isImporting: bulkImportInProgress,
                            onImport: { Task { await importOne(project) } }
                        )
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
                    LibraryGuideFeature(icon: "checkmark.shield", text: "Only compatible Video and Web projects are imported")
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
        SettingsManager.shared.saveWorkshopLibraryRootBookmark(bookmark)
        updateRootAccessState()
        Task { await refreshScan() }
    }

    private func disconnectLibraryRoot() {
        SettingsManager.shared.clearWorkshopLibraryRootBookmark()
        projects = []
        bulkImportInProgress = false
        bulkImportProgress = (0, 0)
        hasLibraryRoot = false
        rootPathSummary = nil
        state = .needsRoot
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
            errorMessage = String(localized: "Workshop folder is unreachable: \(detail). Try re-granting access.", comment: "Workshop library folder access error. The placeholder is the system detail.")
            SettingsManager.shared.clearWorkshopLibraryRootBookmark()
            updateRootAccessState()
            projects = []
            state = .needsRoot
        } catch {
            errorMessage = error.localizedDescription
            projects = []
            state = hasLibraryRoot ? .results : .needsRoot
        }
    }

    private func importOne(_ project: WallpaperEngineLibraryScanner.DiscoveredProject) async {
        let outcome = await importWithLibraryAccess(project)
        switch outcome {
        case .imported, .alreadyKnown, .unsupported:
            await refreshScan()
        case .rejected(let reason):
            errorMessage = reason
        }
    }

    private func bulkImportCompatible() async {
        let candidates = projects.filter { isCompatible($0.type) && !$0.importedAlready }
        guard !candidates.isEmpty else { return }
        bulkImportInProgress = true
        bulkImportProgress = (0, candidates.count)
        var failures: [WPEBulkImportFailureSummary.Rejection] = []

        for (index, project) in candidates.enumerated() {
            bulkImportProgress = (index + 1, candidates.count)
            let outcome = await importWithLibraryAccess(project)
            if case .rejected(let reason) = outcome {
                failures.append(.init(title: project.title, reason: reason))
            }
        }

        bulkImportInProgress = false
        bulkImportProgress = (0, 0)
        await refreshScan()
        errorMessage = WPEBulkImportFailureSummary.message(for: failures)
    }

    /// Re-acquires the persisted root bookmark's security scope for the
    /// duration of one import. Without this, child URLs handed back by the
    /// scanner are unreachable in a sandboxed build because the scanner's
    /// scope ended when `scan()` returned.
    private func importWithLibraryAccess(
        _ project: WallpaperEngineLibraryScanner.DiscoveredProject
    ) async -> ScreenManager.WPELibraryImportOutcome {
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
        return await screenManager.importWPEToLibrary(at: project.folderURL)
    }

    // MARK: - Helpers

    private var compatibleCount: Int {
        projects.filter { isCompatible($0.type) && !$0.importedAlready }.count
    }

    private var unsupportedCount: Int {
        projects.filter { !isCompatible($0.type) }.count
    }

    private func isCompatible(_ type: WPEType) -> Bool {
        switch type {
        case .video, .web: return true
        case .scene, .application, .unknown: return false
        }
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

    private enum PaneState: Equatable {
        case needsRoot
        case scanning
        case results
    }
}

struct WPEBulkImportFailureSummary {
    struct Rejection: Equatable, Sendable {
        let title: String
        let reason: String
    }

    static func message(for rejections: [Rejection]) -> String? {
        guard !rejections.isEmpty else { return nil }
        let header = rejections.count == 1
            ? String(localized: "1 import failed", defaultValue: "1 import failed", comment: "Workshop bulk import failure summary.")
            : String(localized: "\(rejections.count) imports failed", comment: "Workshop bulk import failure summary. The placeholder is the failure count.")
        let visible = rejections.prefix(5).map { "\($0.title): \($0.reason)" }
        let remaining = rejections.count - visible.count
        if remaining > 0 {
            let more = String(localized: "+\(remaining) more", comment: "Workshop bulk import failure summary. The placeholder is additional failure count.")
            return ([header] + visible + [more]).joined(separator: "\n")
        }
        return ([header] + visible).joined(separator: "\n")
    }
}

// MARK: - Card

private struct WorkshopGalleryCard: View {
    let project: WallpaperEngineLibraryScanner.DiscoveredProject
    let isImporting: Bool
    let onImport: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Square preview occupies the full 160pt card width (160×160).
            WPEPreviewView(
                imageURL: project.previewURL,
                securityScopedBookmarkData: project.libraryRootBookmarkData
            )
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 16,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 16,
                        style: .continuous
                    )
                )
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
        .frame(width: 160, height: 240)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .shadow(
            color: Color.black.opacity(isHovering ? 0.18 : 0.06),
            radius: isHovering ? 8 : 4,
            y: isHovering ? 4 : 2
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovering)
        .onHover { isHovering = $0 }
        // Deliberately NOT .accessibilityElement(children: .combine) — that
        // would swallow the inner Import button. Letting SwiftUI infer the
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
        case .video, .web:
            if project.importedAlready {
                Label("In Library", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button(action: onImport) {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(isImporting)
            }
        case .scene:
            Label("Scene · preview only", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    private var typeLabel: String {
        project.type == .unknown ? "?" : project.type.localizedDisplayName
    }

    private var cardAccessibilityLabel: Text {
        if project.importedAlready {
            return Text("\(project.title), \(typeLabel) wallpaper, already in library", comment: "Workshop gallery card a11y label for an already-imported project. Placeholders are project title and project type.")
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
