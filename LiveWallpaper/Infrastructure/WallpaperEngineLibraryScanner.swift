import Foundation

/// Scans a user-granted Steam Workshop root (e.g. `~/Documents/Live Wallpapers/431960/`)
/// and returns metadata for every valid Wallpaper Engine project found inside.
/// Used by the Workshop Library Gallery for bulk-discovery + selective import.
///
/// Off-main: heavy directory enumeration + per-project JSON decoding runs on
/// a detached cooperative task so very large libraries don't hang the UI.
/// Caller (which is @MainActor) is responsible for resolving the persisted
/// bookmark + already-imported set first, since both depend on the
/// `@MainActor`-isolated `SettingsManager`.
///
/// `@unchecked Sendable`: `FileManager.default` is documented thread-safe for
/// the read-only operations we use (enumeration, existence checks). All other
/// stored state is immutable by construction.
final class WallpaperEngineLibraryScanner: @unchecked Sendable {

    enum ScanError: Error, Equatable, Sendable {
        case rootBookmarkMissing
        case rootInaccessible(String)
    }

    /// Snapshot of one project discovered under the workshop root.
    /// Carries the shared `libraryRootBookmarkData` so the gallery can
    /// re-acquire security scope for each child URL after the scan returns —
    /// `scan()`'s own `startAccessingSecurityScopedResource` lifetime ends
    /// with the call.
    struct DiscoveredProject: Sendable, Identifiable {
        let workshopID: String
        let title: String
        let type: WPEType
        let entryFile: String
        let folderURL: URL
        let previewURL: URL?
        let importedAlready: Bool
        let libraryRootBookmarkData: Data
        let dependencyWorkshopIDs: [String]
        let requiresWindowsPlugin: Bool
        let hasScenePackage: Bool

        var id: String { workshopID }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Off-main scan. Resolves `rootBookmarkData`, walks the immediate
    /// children of the root, and parses each `<workshopID>/project.json`.
    /// Children that are not directories or whose project.json is missing
    /// or malformed are silently skipped — they're not part of a WPE
    /// library by definition.
    func scan(
        rootBookmarkData: Data,
        alreadyImportedWorkshopIDs: Set<String>
    ) async throws -> [DiscoveredProject] {
        try await Task.detached(priority: .userInitiated) { [fileManager] in
            try Self.performScan(
                rootBookmarkData: rootBookmarkData,
                alreadyImportedWorkshopIDs: alreadyImportedWorkshopIDs,
                fileManager: fileManager
            )
        }.value
    }

    private static func performScan(
        rootBookmarkData: Data,
        alreadyImportedWorkshopIDs: Set<String>,
        fileManager: FileManager
    ) throws -> [DiscoveredProject] {
        let rootURL: URL
        let effectiveRootBookmarkData: Data
        switch SecurityScopedBookmarkResolver.shared.resolve(
            rootBookmarkData,
            target: .workshopLibraryRoot
        ) {
        case .success(let resolved):
            rootURL = resolved.url
            // Carry the refreshed bookmark (if the resolver auto-refreshed a
            // stale one) into every DiscoveredProject so the gallery's
            // follow-up apply/prepare doesn't re-resolve the original stale
            // blob and burn another grace use.
            effectiveRootBookmarkData = resolved.bookmarkData
        case .failure(let failure):
            throw ScanError.rootInaccessible(failure.errorDescription ?? "Unknown bookmark failure")
        }

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
                importedAlready: alreadyImportedWorkshopIDs.contains(project.workshopID),
                libraryRootBookmarkData: effectiveRootBookmarkData,
                dependencyWorkshopIDs: project.dependencyWorkshopIDs,
                requiresWindowsPlugin: project.requiresWindowsPlugin,
                hasScenePackage: fileManager.fileExists(
                    atPath: child.appendingPathComponent("scene.pkg").path
                )
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

    private static func compatibilityRank(_ type: WPEType) -> Int {
        switch type {
        case .video, .web:           return 0
        case .scene:                 return 1
        case .application, .unknown: return 2
        }
    }
}
