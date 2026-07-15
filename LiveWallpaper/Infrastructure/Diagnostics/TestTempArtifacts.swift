#if DEBUG && !LITE_BUILD
import Foundation

/// DEBUG-only accounting for the temp directories test suites leave behind in
/// the app container's `tmp/`. No shipping code path writes any of these names,
/// so this exists purely to keep a developer's container from growing across
/// repeated test runs.
enum TestTempArtifacts {

    struct Summary: Equatable {
        var itemCount: Int
        var totalBytes: UInt64

        static let empty = Summary(itemCount: 0, totalBytes: 0)
        var isEmpty: Bool { itemCount == 0 }
    }

    /// Test-owned name prefixes, matched against the *direct children* of `tmp/`.
    ///
    /// An explicit allowlist rather than a "name ends in a UUID" heuristic on
    /// purpose: production stages UUID-named directories in the same folder
    /// (`WPEPackageSceneAssetProvider.stagingDirectoryNamePrefix`), and a live
    /// wallpaper reading in place from one must never become a purge candidate.
    /// Omitting a prefix only under-reports; matching one wrongly deletes real
    /// data — so anything ambiguous is deliberately left out.
    static let knownPrefixes: [String] = [
        "AtomicFileStoreTests-",
        "ClaudeSessionScannerTests-",
        "CodexAgentSourceTests-",
        "ConfigurationPorterTests-",
        "JSONLTailReaderTests-",
        "LWCSPPkgAudit-",
        "LWCompatibility-",
        "LWLifecycle-",
        "LWNavPolicy-",
        "LWSchemeTest-",
        "LWView-",
        "LiveWallpaper-local-access-",
        "LiveWallpaper-local-video-",
        "LiveWallpaperSchemeTests-",
        "MonitorTailCursorStoreTests-",
        "ProtocolizedDependencies-",
        "SceneResourceResolverTests-",
        "SettingsManagerMigrationTests-",
        "SettingsManagerUnwritable-",
        "UsageBackfill-",
        "UsageOversized-",
        "UsageStream-",
        "W3GameModeDetector-",
        "WPEDelete-",
        "WPEDependencyMountResolverTests-",
        "WPEMetalDiagnostics-",
        "WPEMetalSceneDependency-",
        "WPEMetalSceneRenderer-",
        "WPEMultiRootResourceResolverTests-",
        "WPEProjectPropertiesTests-",
        "WPERenderGraphBuilderTests-",
        "WPERenderPipelineBuilderSpriteSheetTests-",
        "WPERenderPipelineBuilderTests-",
        "WPESceneCapabilityClassifierTests-",
        "WPEWebPropertyBridgeTests-",
        "claude-ratelimit-",
        "custom-shader-store-",
        "inplace-",
        "lw-empty-",
        "lw-steamcmd-",
        "msdf-e2e-",
        "msdf-payload-",
        "msdf-prewarm-",
        "reclaim-",
        "workshop-query-cache-",
        "wpe-match-test-",
        "wpe-oracle-",
        "wpe-pacing-",
        "wpe-preview-",
        "wpe-resolution-",
        "wpe-source-video-",
        "wpe-source-web-",
        "wpe-tex-video-test-"
    ]

    /// Prefixes with no producer left — all belonged to the corpus system retired
    /// in `3324b442`. Still swept, to clear pre-retirement leftovers off developer
    /// disks; kept apart from `knownPrefixes` so that list stays a statement about
    /// live tests, and so these have a deletion criterion (no machine still holds
    /// corpus-era temp data) instead of accreting forever.
    static let retiredPrefixes: [String] = [
        "WPEMetalRotatedQuad-",
        "WPEMetalVisualGate-",
        "wpe-corpus-",
        "wpe-e2e-",
        "wpe-empty-",
        "wpe-tex-scan-",
        "wpe-visual-"
    ]

    /// Container `tmp/`. `NSTemporaryDirectory()` is the same root the tests write to.
    static var rootURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func candidates(fileManager fm: FileManager) -> [URL] {
        guard let children = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let prefixes = knownPrefixes + retiredPrefixes
        return children.filter { url in
            let name = url.lastPathComponent
            return prefixes.contains { name.hasPrefix($0) }
        }
    }

    /// Walks every candidate to sum its allocated footprint. Call off the main
    /// actor — this is a full filesystem walk.
    static func scan(fileManager fm: FileManager = .default) -> Summary {
        let items = candidates(fileManager: fm)
        var bytes: UInt64 = 0
        for url in items {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            bytes += isDirectory
                ? WPEStoragePaths.allocatedBytes(at: url, fileManager: fm)
                : UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return Summary(itemCount: items.count, totalBytes: bytes)
    }

    /// Deletes every candidate outright (not to the Trash — this is scratch data
    /// no user ever created). Returns the freed footprint. Call off the main actor.
    @discardableResult
    static func purge(fileManager fm: FileManager = .default) -> UInt64 {
        let before = scan(fileManager: fm)
        for url in candidates(fileManager: fm) {
            try? fm.removeItem(at: url)
        }
        return before.totalBytes
    }
}
#endif
