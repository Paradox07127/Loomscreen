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

    /// Concatenates one type's sources across the files it was split into —
    /// `Foo.swift` plus `Foo+Part.swift` / `FooTypes.swift` siblings.
    ///
    /// A `contains` assertion anchored to a single path stops enforcing the
    /// moment the declaration it targets moves to a sibling file, and a pure
    /// move is exactly the refactor that moves it. Addressing the component
    /// rather than the file keeps the assertion meaningful across splits;
    /// `noSourcesMatch` keeps a typo'd prefix loud instead of vacuously true.
    static func componentSource(under directory: String, namePrefix: String) throws -> String {
        let files = swiftFiles(under: directory)
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(namePrefix) }
        guard !files.isEmpty else { throw SweepError.noSourcesMatch(directory: directory, prefix: namePrefix) }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    enum SweepError: Error, CustomStringConvertible {
        case noSourcesMatch(directory: String, prefix: String)

        var description: String {
            switch self {
            case let .noSourcesMatch(directory, prefix):
                return "No .swift file under \(directory) starts with \(prefix) — the scan is misconfigured, not passing."
            }
        }
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

    @Test("A component sweep spans the files its type was split into")
    func componentSourceSpansSplitParts() throws {
        let executor = try RepositoryRoot.componentSource(under: "LiveWallpaper/Runtime", namePrefix: "WPEMetalRenderExecutor")
        // One declaration from the class body and one from an extension file.
        #expect(executor.contains("final class WPEMetalRenderExecutor"))
        #expect(executor.contains("func present("))
    }

    @Test("A component sweep matching nothing throws instead of returning empty")
    func componentSourceRejectsEmptySweep() {
        #expect(throws: RepositoryRoot.SweepError.self) {
            try RepositoryRoot.componentSource(under: "LiveWallpaper/Runtime", namePrefix: "NoSuchTypeName")
        }
    }
}
