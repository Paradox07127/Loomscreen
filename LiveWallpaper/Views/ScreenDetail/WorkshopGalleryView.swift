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

    private let scanner = WallpaperEngineLibraryScanner()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if SettingsManager.shared.loadWorkshopLibraryRootBookmark() != nil {
                Task { await refreshScan() }
            } else {
                state = .needsRoot
            }
        }
        .alert("Library Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workshop Library")
                    .font(.title3.bold())
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if case .results = state {
                Button {
                    Task { await refreshScan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .accessibilityHint("Re-scan the workshop folder for new projects")
                .disabled(bulkImportInProgress)

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
                .accessibilityHint("Imports every Video and Web project not already in your library")
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
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        switch state {
        case .needsRoot:
            return "Choose your Steam Wallpaper Engine folder to discover projects"
        case .scanning:
            return "Scanning…"
        case .results:
            return "\(projects.count) projects · \(compatibleCount) compatible · \(unsupportedCount) preview-only"
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
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text("Grant access to your Steam library")
                    .font(.title3.bold())
                Text("Pick the Wallpaper Engine projects folder once — usually `~/Documents/Live Wallpapers/<appid>/`")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                presentFolderGrant()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.top, 4)
            .accessibilityHint("Opens a folder chooser to grant scanning access")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
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

    private var resultsView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 180), spacing: 14), count: 4),
                alignment: .leading,
                spacing: 14
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

    // MARK: - Actions

    private func presentFolderGrant() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Library Access"
        panel.message = "Select your Wallpaper Engine projects folder"

        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let lwDir = docs.appendingPathComponent("Live Wallpapers")
            if FileManager.default.fileExists(atPath: lwDir.path) {
                panel.directoryURL = lwDir
            }
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bookmark = ResourceUtilities.createBookmark(for: url) else {
            errorMessage = "Couldn't create a security-scoped bookmark for that folder."
            return
        }
        SettingsManager.shared.saveWorkshopLibraryRootBookmark(bookmark)
        Task { await refreshScan() }
    }

    private func refreshScan() async {
        state = .scanning
        do {
            let discovered = try await scanner.scan()
            projects = discovered
            state = .results
        } catch WallpaperEngineLibraryScanner.ScanError.rootBookmarkMissing {
            state = .needsRoot
        } catch WallpaperEngineLibraryScanner.ScanError.rootInaccessible(let detail) {
            errorMessage = "Workshop folder is unreachable: \(detail). Try re-granting access."
            SettingsManager.shared.clearWorkshopLibraryRootBookmark()
            state = .needsRoot
        } catch {
            errorMessage = error.localizedDescription
            state = .needsRoot
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

        for (index, project) in candidates.enumerated() {
            bulkImportProgress = (index + 1, candidates.count)
            _ = await importWithLibraryAccess(project)
        }

        bulkImportInProgress = false
        bulkImportProgress = (0, 0)
        await refreshScan()
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

    private enum PaneState: Equatable {
        case needsRoot
        case scanning
        case results
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
            WPEPreviewView(
                imageURL: project.previewURL,
                securityScopedBookmarkData: project.libraryRootBookmarkData
            )
                .frame(height: 110)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 14,
                        style: .continuous
                    )
                )
                .overlay(alignment: .topTrailing) {
                    typeBadge
                        .padding(8)
                }

            VStack(alignment: .leading, spacing: 8) {
                Text(project.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(project.title), \(project.type.rawValue) wallpaper\(project.importedAlready ? ", already in library" : "")")

                actionButton
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: 220)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .shadow(
            color: Color.black.opacity(isHovering ? 0.15 : 0.05),
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
            Text(typeLabel)
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
        switch project.type {
        case .video:        return "Video"
        case .web:          return "Web"
        case .scene:        return "Scene"
        case .application:  return "App"
        case .unknown:      return "?"
        }
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
