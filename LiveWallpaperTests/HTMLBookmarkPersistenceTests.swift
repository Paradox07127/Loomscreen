import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

@Suite("Persisted local HTML bookmark refresh")
@MainActor
struct HTMLBookmarkPersistenceTests {
    private let original = Data("stale-html-bookmark".utf8)
    private let refreshed = Data("refreshed-html-bookmark".utf8)

    @Test("Stale folder bookmark validates, CAS-saves, and survives manager restart")
    func staleFolderBookmarkPersistsAcrossRestart() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("site", isDirectory: true)
        let index = folder.appendingPathComponent("index.html")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("<title>fixture</title>".utf8).write(to: index)

        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (folder, true) },
            refreshData: { _ in refreshed }
        )
        let configurationRoot = root.appendingPathComponent("configuration", isDirectory: true)
        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: configurationRoot),
            bookmarkResolver: resolver
        )
        let screenID: UInt32 = 980_001
        manager.replaceAllConfigurations([
            ScreenConfiguration(
                screenID: screenID,
                wallpaper: .html(
                    source: .folder(bookmarkData: original, indexFileName: "index.html"),
                    config: .default
                )
            ),
        ])

        #expect(manager.validateConfiguration(for: screenID))
        let updated = try #require(manager.getConfiguration(for: screenID))
        #expect(updated.savedHTMLSource == .folder(bookmarkData: refreshed, indexFileName: "index.html"))
        #expect(
            updated.activeWallpaper
                == .html(
                    source: .folder(bookmarkData: refreshed, indexFileName: "index.html"),
                    config: .default
                )
        )

        await manager.flushPendingConfigurationWrites()
        let freshResolver = SecurityScopedBookmarkResolver(
            resolveData: { data in
                #expect(data == refreshed)
                return (folder, false)
            },
            refreshData: { _ in
                Issue.record("A persisted refreshed bookmark must not refresh again")
                return Data()
            }
        )
        let reloaded = SettingsManager(
            directory: ConfigurationDirectory(root: configurationRoot),
            bookmarkResolver: freshResolver
        )

        #expect(reloaded.getConfiguration(for: screenID)?.savedHTMLSource == updated.savedHTMLSource)
        #expect(reloaded.validateConfiguration(for: screenID))
    }

    @Test("File bookmarks update active and saved copies together")
    func fileBookmarkUpdatesBothOwners() throws {
        let configuration = ScreenConfiguration(
            screenID: 980_002,
            wallpaper: .html(source: .file(bookmarkData: original), config: .default)
        )

        let updated = try #require(
            configuration.replacingHTMLBookmark(matching: original, with: refreshed)
        )

        #expect(updated.savedHTMLSource == .file(bookmarkData: refreshed))
        #expect(updated.activeWallpaper == .html(source: .file(bookmarkData: refreshed), config: .default))
    }

    @Test("A late stale refresh cannot overwrite a newer user grant")
    func staleRefreshCompareAndSwapRejectsRegrant() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        let screenID: UInt32 = 980_003
        let newerGrant = Data("new-user-grant".utf8)
        manager.replaceAllConfigurations([
            ScreenConfiguration(
                screenID: screenID,
                wallpaper: .html(source: .file(bookmarkData: newerGrant), config: .default)
            ),
        ])

        #expect(!manager.persistRefreshedHTMLBookmark(
            matching: original,
            with: refreshed,
            for: screenID
        ))

        let current = try #require(manager.getConfiguration(for: screenID))
        #expect(current.savedHTMLSource == .file(bookmarkData: newerGrant))
        #expect(current.activeWallpaper == .html(source: .file(bookmarkData: newerGrant), config: .default))
        #expect(current.replacingHTMLBookmark(matching: original, with: refreshed) == nil)
    }

    @Test("Runtime builder carries refreshed HTML Data into its effective source and owner")
    func runtimeBuilderPersistsHTMLRefresh() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        let screenID: UInt32 = 980_004
        let source = HTMLSource.folder(bookmarkData: original, indexFileName: "index.html")
        manager.replaceAllConfigurations([
            ScreenConfiguration(
                screenID: screenID,
                wallpaper: .html(source: source, config: .default)
            ),
        ])
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (root, true) },
            refreshData: { _ in refreshed }
        )
        let builder = AmbientWallpaperSessionBuilder(bookmarkResolver: resolver)

        let effective = builder.refreshingHTMLSource(source) { original, refreshed in
            _ = manager.persistRefreshedHTMLBookmark(
                matching: original,
                with: refreshed,
                for: screenID
            )
        }

        #expect(effective == .folder(bookmarkData: refreshed, indexFileName: "index.html"))
        let persisted = try #require(manager.getConfiguration(for: screenID))
        #expect(persisted.savedHTMLSource == effective)
        #expect(persisted.activeWallpaper == .html(source: effective, config: .default))
    }

    @Test("Detached callers hop to the MainActor HTML owner instead of invoking an unsafe Target")
    func detachedHTMLRefreshIsActorSafe() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        let screenID: UInt32 = 980_005
        manager.replaceAllConfigurations([
            ScreenConfiguration(
                screenID: screenID,
                wallpaper: .html(source: .file(bookmarkData: original), config: .default)
            ),
        ])

        let didPersist = await Task.detached { [manager, original, refreshed] in
            await manager.persistRefreshedHTMLBookmark(
                matching: original,
                with: refreshed,
                for: screenID
            )
        }.value

        #expect(didPersist)
        #expect(manager.getConfiguration(for: screenID)?.savedHTMLSource == .file(bookmarkData: refreshed))
    }

    @Test("WPE session resolution refreshes screen and history owners without losing effective Data")
    func wpeRuntimeRefreshPersistsEveryOwner() async throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationRoot = root.appendingPathComponent("configuration", isDirectory: true)
        let manager = SettingsManager(directory: ConfigurationDirectory(root: configurationRoot))
        let origin = Self.makeWPEOrigin(bookmark: original)
        let entry = WPEHistoryEntry(
            origin: origin,
            importedAt: Date(timeIntervalSince1970: 100),
            lastUsedAt: Date(timeIntervalSince1970: 200),
            sizeBytes: 4096
        )
        manager.recordWPEImport(entry)

        var configuration = ScreenConfiguration(
            screenID: 980_006,
            wallpaper: .html(
                source: .folder(bookmarkData: original, indexFileName: "index.html"),
                config: .default
            )
        )
        configuration.wpeOrigin = origin
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (root, true) },
            refreshData: { _ in refreshed }
        )
        let builder = AmbientWallpaperSessionBuilder(bookmarkResolver: resolver)

        let effective = try #require(builder.refreshingWPEOrigin(origin) { staleOrigin, refreshed in
            configuration = configuration.replacingWPEOriginBookmark(
                workshopID: staleOrigin.workshopID,
                matching: staleOrigin.sourceFolderBookmark,
                with: refreshed
            ) ?? configuration
            _ = manager.replaceWPEHistorySourceBookmark(
                workshopID: staleOrigin.workshopID,
                matching: staleOrigin.sourceFolderBookmark,
                with: refreshed
            )
        })

        #expect(effective.origin.sourceFolderBookmark == refreshed)
        #expect(effective.url == root)
        #expect(configuration.wpeOrigin?.sourceFolderBookmark == refreshed)
        #expect(configuration.savedHTMLSource == .folder(bookmarkData: refreshed, indexFileName: "index.html"))
        #expect(
            configuration.activeWallpaper
                == .html(
                    source: .folder(bookmarkData: refreshed, indexFileName: "index.html"),
                    config: .default
                )
        )
        let updatedHistory = try #require(manager.loadGlobalSettings().recentWPEImports.first)
        #expect(updatedHistory.origin.sourceFolderBookmark == refreshed)
        #expect(updatedHistory.importedAt == entry.importedAt)
        #expect(updatedHistory.lastUsedAt == entry.lastUsedAt)
        #expect(updatedHistory.sizeBytes == entry.sizeBytes)

        await manager.flushPendingConfigurationWrites()
        let reloaded = SettingsManager(directory: ConfigurationDirectory(root: configurationRoot))
        #expect(reloaded.loadGlobalSettings().recentWPEImports.first?.origin.sourceFolderBookmark == refreshed)
    }

    @Test("WPE refresh CAS rejects newer screen and history grants")
    func wpeRefreshRejectsConcurrentRegrant() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SettingsManager(directory: ConfigurationDirectory(root: root))
        let newerGrant = Data("newer-wpe-grant".utf8)
        let newerOrigin = Self.makeWPEOrigin(bookmark: newerGrant)
        var configuration = ScreenConfiguration(
            screenID: 980_007,
            wallpaper: .scene(Self.makeSceneDescriptor())
        )
        configuration.wpeOrigin = newerOrigin
        manager.recordWPEImport(WPEHistoryEntry(origin: newerOrigin, importedAt: Date()))

        #expect(configuration.replacingWPEOriginBookmark(
            workshopID: newerOrigin.workshopID,
            matching: original,
            with: refreshed
        ) == nil)
        #expect(!manager.replaceWPEHistorySourceBookmark(
            workshopID: newerOrigin.workshopID,
            matching: original,
            with: refreshed
        ))
        #expect(manager.loadGlobalSettings().recentWPEImports.first?.origin.sourceFolderBookmark == newerGrant)
    }

    @Test("Settings persistence exposes no executor-unsafe HTML Target")
    func actorSafetySourceContract() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/App/SettingsManager.swift")
        #expect(!source.contains("htmlBookmarkRefreshTarget"))
        #expect(!source.contains("MainActor.assumeIsolated"))
        #expect(source.contains("func persistRefreshedHTMLBookmark("))
    }

    @Test("ScreenManager refreshes HTML before source identity and policy consumers")
    func screenManagerUsesEffectiveHTMLSourceForWholeRuntimeChain() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/App/ScreenManager+Monitor.swift")
        let start = try #require(source.range(of: "case .html(let source, let htmlConfig):"))
        let end = try #require(source.range(
            of: "case .metalShader",
            range: start.upperBound..<source.endIndex
        ))
        let htmlCase = source[start.lowerBound..<end.lowerBound]
        let refresh = try #require(htmlCase.range(of: "refreshingHTMLSource("))
        let leader = try #require(htmlCase.range(of: "isAudioLeader(source: effectiveSource"))
        let policy = try #require(htmlCase.range(of: "runtimeConfig(\n                source: effectiveSource"))
        let builder = try #require(htmlCase.range(of: "makeHTMLSession(\n                source: effectiveSource"))

        #expect(refresh.lowerBound < leader.lowerBound)
        #expect(leader.lowerBound < policy.lowerBound)
        #expect(policy.lowerBound < builder.lowerBound)
        #expect(source.contains("func persistRuntimeHTMLBookmarkRefresh("))
        #expect(source.contains("func persistRuntimeWPEBookmarkRefresh("))
    }

    @Test("HTML setter preflights a one-shot stale bookmark before compatibility probes")
    func htmlSetterPreflightsBeforeCompatibilityProbe() throws {
        let root = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("project.json"))
        try Data("<canvas></canvas>".utf8).write(to: root.appendingPathComponent("index.html"))

        let state = OneShotHTMLBookmarkState(
            original: original,
            refreshed: refreshed,
            url: root
        )
        let resolver = state.makeResolver()
        let builder = AmbientWallpaperSessionBuilder(bookmarkResolver: resolver)
        let source = HTMLSource.folder(bookmarkData: original, indexFileName: "index.html")

        let effective = builder.refreshingHTMLSource(source)
        _ = HTMLWallpaperCompatibilityPolicy.shouldAutoEnablePhysicalPixelLayout(
            effective,
            bookmarkResolver: resolver
        )

        #expect(effective.localBookmarkData == refreshed)
        #expect(state.originalResolveCount == 1)
        #expect(state.refreshedResolveCount == 1)

        let coordinatorSource = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Coordinators/HTMLWallpaperCoordinator.swift"
        )
        let setter = try #require(coordinatorSource.range(of: "func setWallpaper("))
        let nextMethod = try #require(coordinatorSource.range(
            of: "func setWallpaperPreservingConfig",
            range: setter.upperBound..<coordinatorSource.endIndex
        ))
        let body = coordinatorSource[setter.lowerBound..<nextMethod.lowerBound]
        let preflight = try #require(body.range(of: "let effectiveSource = prepareSource("))
        let compatibility = try #require(body.range(
            of: "shouldAutoEnablePhysicalPixelLayout(effectiveSource)"
        ))
        #expect(preflight.lowerBound < compatibility.lowerBound)
        #expect(!body.contains("shouldAutoEnablePhysicalPixelLayout(source)"))
    }

    @Test("HTML bookmark apply carries shortcut identity and WPE provenance")
    func htmlBookmarkApplyCarriesOwnerContext() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/App/ScreenManager+Bookmarks.swift")
        #expect(source.contains("bookmarkID: bookmark.id"))
        #expect(source.contains("wpeOrigin: bookmark.wpeOrigin"))
    }

    @Test("Security-scoped access helper keeps stop in defer")
    func securityScopeContractRemainsBalanced() throws {
        let source = try RepositoryRoot.source(
            "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/Persistence/SecurityScopedBookmarkResolver.swift"
        )
        guard let start = source.range(of: "public static func withScopedAccess"),
              let end = source.range(of: "extension SecurityScopedBookmarkResolver", range: start.upperBound..<source.endIndex)
        else {
            Issue.record("Could not isolate withScopedAccess")
            return
        }
        let helper = source[start.lowerBound..<end.lowerBound]
        #expect(helper.contains("let didStart = url.startAccessingSecurityScopedResource()"))
        #expect(helper.contains("defer { if didStart { url.stopAccessingSecurityScopedResource() } }"))
    }

    private static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLBookmarkPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeWPEOrigin(bookmark: Data) -> WPEOrigin {
        WPEOrigin(
            workshopID: "bookmark-refresh-fixture",
            title: "Bookmark Refresh Fixture",
            originalType: .web,
            sourceFolderBookmark: bookmark,
            cacheRelativePath: nil,
            previewFileName: "preview.png",
            entryFile: "index.html",
            resourceLocation: .sourceFolder,
            originKind: .workshopImport
        )
    }

    private static func makeSceneDescriptor() -> SceneDescriptor {
        SceneDescriptor(
            workshopID: "bookmark-refresh-fixture",
            cacheRelativePath: "wpe-cache/bookmark-refresh-fixture",
            entryFile: "scene.json",
            capabilityTier: .imageOnly
        )
    }
}

private final class OneShotHTMLBookmarkState: @unchecked Sendable {
    private let lock = NSLock()
    private let original: Data
    private let refreshed: Data
    private let url: URL
    private var originalCount = 0
    private var refreshedCount = 0

    init(original: Data, refreshed: Data, url: URL) {
        self.original = original
        self.refreshed = refreshed
        self.url = url
    }

    var originalResolveCount: Int { lock.withLock { originalCount } }
    var refreshedResolveCount: Int { lock.withLock { refreshedCount } }

    func makeResolver() -> SecurityScopedBookmarkResolver {
        SecurityScopedBookmarkResolver(
            resolveData: { [self] data in
                try lock.withLock {
                    if data == original {
                        originalCount += 1
                        guard originalCount == 1 else {
                            throw NSError(domain: "OneShotHTMLBookmarkState", code: 1)
                        }
                        return (url, true)
                    }
                    guard data == refreshed else {
                        throw NSError(domain: "OneShotHTMLBookmarkState", code: 2)
                    }
                    refreshedCount += 1
                    return (url, false)
                }
            },
            refreshData: { [refreshed] _ in refreshed }
        )
    }
}
