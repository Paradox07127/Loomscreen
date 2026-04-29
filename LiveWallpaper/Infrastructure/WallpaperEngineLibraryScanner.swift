import Foundation

/// Scans a user-granted Steam Workshop root (e.g. `~/Documents/Live Wallpapers/431960/`)
/// and returns metadata for every valid Wallpaper Engine project found inside.
/// Used by the Workshop Library Gallery for bulk-discovery + selective import.
@MainActor
final class WallpaperEngineLibraryScanner {

    enum ScanError: Error, Equatable, Sendable {
        case rootBookmarkMissing
        case rootInaccessible(String)
    }

    /// Snapshot of one project discovered under the workshop root.
    /// Carries the shared `libraryRootBookmarkData` so the gallery can re-acquire
    /// security scope for each child URL after the scan returns — `scan()`'s
    /// own `startAccessingSecurityScopedResource` lifetime ends with the call.
    struct DiscoveredProject: Sendable, Identifiable {
        let workshopID: String
        let title: String
        let type: WPEType
        let entryFile: String
        let folderURL: URL
        let previewURL: URL?
        let importedAlready: Bool
        let libraryRootBookmarkData: Data

        var id: String { workshopID }
    }

    private let fileManager: FileManager
    private let importedWorkshopIDs: () -> Set<String>

    init(
        fileManager: FileManager = .default,
        importedWorkshopIDs: @escaping () -> Set<String> = {
            Set(SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID))
        }
    ) {
        self.fileManager = fileManager
        self.importedWorkshopIDs = importedWorkshopIDs
    }

    /// Resolves the persisted security-scoped bookmark and walks the immediate
    /// children of the root, parsing each `<workshopID>/project.json`.
    /// Skips children that are not directories or whose project.json is
    /// missing / malformed — they're not part of a WPE library by definition.
    func scan() async throws -> [DiscoveredProject] {
        guard let bookmark = SettingsManager.shared.loadWorkshopLibraryRootBookmark() else {
            throw ScanError.rootBookmarkMissing
        }

        var isStale = false
        let rootURL = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        let didStartScope = rootURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { rootURL.stopAccessingSecurityScopedResource() } }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            throw ScanError.rootInaccessible(error.localizedDescription)
        }

        let alreadyImported = importedWorkshopIDs()
        var results: [DiscoveredProject] = []

        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard fileManager.fileExists(atPath: child.appendingPathComponent("project.json").path) else { continue }

            guard let project = try? WallpaperEngineProject.read(from: child) else { continue }

            let previewURL: URL? = {
                guard let name = project.previewFileName else { return nil }
                let candidate = child.appendingPathComponent(name)
                return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
            }()

            results.append(DiscoveredProject(
                workshopID: project.workshopID,
                title: project.title,
                type: project.type,
                entryFile: project.entryFile,
                folderURL: child,
                previewURL: previewURL,
                importedAlready: alreadyImported.contains(project.workshopID),
                libraryRootBookmarkData: bookmark
            ))
        }

        // Order: compatible first (video / web), then unsupported, then by title.
        results.sort { lhs, rhs in
            let lhsRank = compatibilityRank(lhs.type)
            let rhsRank = compatibilityRank(rhs.type)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        return results
    }

    private func compatibilityRank(_ type: WPEType) -> Int {
        switch type {
        case .video, .web:           return 0
        case .scene:                 return 1
        case .application, .unknown: return 2
        }
    }
}
