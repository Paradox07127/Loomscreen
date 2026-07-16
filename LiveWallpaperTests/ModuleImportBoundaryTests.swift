import Foundation
import Testing

@Suite("App module import boundary")
struct ModuleImportBoundaryTests {
    private let expectedLegacyExports: Set<String> = [
        "LiveWallpaper/App/CoreExports.swift:LiveWallpaperCore",
        "LiveWallpaper/App/CoreExports.swift:LiveWallpaperProFeatures",
        "LiveWallpaper/App/CoreExports.swift:LiveWallpaperProWPE",
        "LiveWallpaper/App/CoreExports.swift:LiveWallpaperSharedUI",
        "LiveWallpaper/App/CoreExports.swift:LiveWallpaperVideoWeb",
    ]

    @Test("Blanket re-exports cannot grow or move")
    func exportedImportInventoryIsFrozen() throws {
        let sources = RepositoryRoot.swiftFiles(under: "LiveWallpaper")
        #expect(!sources.isEmpty)

        var actual: Set<String> = []
        for file in sources {
            let relativePath = file.path.replacingOccurrences(
                of: RepositoryRoot.url.path + "/",
                with: ""
            )
            let source = try String(contentsOf: file, encoding: .utf8)
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let prefix = "@_exported import "
                guard line.hasPrefix(prefix) else { continue }
                actual.insert(relativePath + ":" + line.dropFirst(prefix.count))
            }
        }

        #expect(
            actual == expectedLegacyExports,
            Comment(rawValue: "Legacy re-export surface changed: \(actual.sorted())")
        )
    }

    @Test("Migrated platform leaves keep their direct package imports", arguments: [
        ("LiveWallpaper/Infrastructure/Platform/AppleAerialsLibrary.swift", "LiveWallpaperCore"),
        ("LiveWallpaper/Infrastructure/Platform/DesktopPictureFrameExtractor.swift", "LiveWallpaperCore"),
        ("LiveWallpaper/Infrastructure/Platform/GlobalShortcutManager.swift", "LiveWallpaperCore"),
        ("LiveWallpaper/Infrastructure/Platform/WPEStorageInventory.swift", "LiveWallpaperProWPE"),
        ("LiveWallpaper/Infrastructure/Platform/WPEStoragePaths.swift", "LiveWallpaperProWPE"),
    ])
    func migratedPlatformLeafKeepsExplicitImport(relativePath: String, module: String) throws {
        let source = try RepositoryRoot.source(relativePath)
        #expect(
            source.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "import \(module)" },
            Comment(rawValue: "\(relativePath) must import \(module) directly")
        )
    }
}
