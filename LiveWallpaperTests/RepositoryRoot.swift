import Foundation
import Testing

/// Single anchor for every source-scanning test.
///
/// Two idioms preceded this and both fail silently under a file-tree reshuffle:
/// walking up until `lastPathComponent == "LiveWallpaperTests"` *hangs* if that
/// directory is renamed (`/` is a fixed point of `deleteLastPathComponent`), and
/// two blind `deletingLastPathComponent()` calls resolve to the wrong root the
/// moment a test file moves into a subdirectory. Probing upward for the
/// `.xcodeproj` bundle terminates on both the found and not-found paths and does
/// not care what any directory is named.
enum RepositoryRoot {
    static let projectFileName = "LiveWallpaper.xcodeproj"

    static let url: URL = {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return ascendToProject(from: sourceDirectory)
            ?? ascendToProject(from: workingDirectory)
            ?? sourceDirectory.deletingLastPathComponent()
    }()

    static func url(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    /// Recursively collects `.swift` files under a repo-relative directory.
    /// Callers must assert the result is non-empty — an empty sweep is how a
    /// scanning test silently stops enforcing anything.
    static func swiftFiles(under relativePath: String) -> [URL] {
        swiftFiles(underURL: url(relativePath))
    }

    static func swiftFiles(underURL root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var collected: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular { collected.append(url) }
        }
        return collected.sorted { $0.path < $1.path }
    }

    private static func ascendToProject(from directory: URL) -> URL? {
        var candidate = directory
        while true {
            let project = candidate.appendingPathComponent(projectFileName)
            if FileManager.default.fileExists(atPath: project.path) { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}

@Suite("Repository root anchor")
struct RepositoryRootTests {
    @Test("Resolves to the directory holding the Xcode project")
    func resolvesToProjectDirectory() {
        let manager = FileManager.default
        #expect(
            manager.fileExists(atPath: RepositoryRoot.url(RepositoryRoot.projectFileName).path),
            Comment(rawValue: "Repo root resolved to \(RepositoryRoot.url.path), which holds no \(RepositoryRoot.projectFileName)")
        )
        #expect(manager.fileExists(atPath: RepositoryRoot.url("LiveWallpaper").path))
        #expect(manager.fileExists(atPath: RepositoryRoot.url("Packages").path))
    }

    @Test("Swift sweeps under a real directory are non-empty and recursive")
    func swiftSweepIsRecursive() {
        let files = RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views")
        #expect(!files.isEmpty)
        #expect(files.contains { $0.path.contains("/Views/ScreenDetail/") }, "Sweep is not descending into subdirectories")
    }

    @Test("A missing directory sweeps to empty rather than resolving somewhere else")
    func missingDirectorySweepsEmpty() {
        #expect(RepositoryRoot.swiftFiles(under: "LiveWallpaper/DirectoryThatDoesNotExist").isEmpty)
    }
}
