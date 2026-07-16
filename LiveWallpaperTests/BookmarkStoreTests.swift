import Testing
import Foundation
@testable import LiveWallpaper

// MARK: - In-memory persistence

@MainActor
private final class InMemoryBookmarkPersistence: BookmarkPersisting {
    var stored: [WallpaperBookmark] = []
    private(set) var saveCount = 0

    func load() -> [WallpaperBookmark] { stored }

    func save(_ bookmarks: [WallpaperBookmark]) {
        stored = bookmarks
        saveCount += 1
    }
}

// MARK: - BookmarkStore behavior

@Suite("BookmarkStore behavior")
@MainActor
struct BookmarkStoreTests {

    private func makeStore(seed: [WallpaperBookmark] = []) -> (BookmarkStore, InMemoryBookmarkPersistence) {
        let persistence = InMemoryBookmarkPersistence()
        persistence.stored = seed
        return (BookmarkStore(persistence: persistence), persistence)
    }

    private func sampleVideoContent(byte: UInt8 = 0x01) -> WallpaperContent {
        .video(bookmarkData: Data([byte]))
    }

    private func sampleHTMLContent(_ host: String = "example.com") -> WallpaperContent {
        .html(source: .url(URL(string: "https://\(host)")!), config: .default)
    }

    private func sampleSceneContent(workshopID: String = "scene-bookmark") -> WallpaperContent {
        .scene(SceneDescriptor(
            workshopID: workshopID,
            cacheRelativePath: "wpe-cache/\(workshopID)",
            entryFile: "scene.json",
            capabilityTier: .imageOnly,
            dependencyWorkshopIDs: ["123456789012"]
        ))
    }

    private func sampleWPEOrigin(
        workshopID: String = "scene-bookmark",
        bookmark: Data = Data([0xA1, 0xB2])
    ) -> WPEOrigin {
        WPEOrigin(
            workshopID: workshopID,
            title: "Bookmarked Scene",
            originalType: .scene,
            sourceFolderBookmark: bookmark,
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: "preview.jpg",
            entryFile: "scene.json",
            resourceLocation: .cache,
            dependencyWorkshopIDs: ["123456789012"]
        )
    }

    @Test("Loads seeded bookmarks on init")
    func loadsSeed() {
        let seed = [WallpaperBookmark(label: "Seed", content: sampleVideoContent())]
        let (store, _) = makeStore(seed: seed)
        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.label == "Seed")
    }

    @Test("add appends and persists")
    func addAppendsAndPersists() {
        let (store, persistence) = makeStore()
        let added = store.add(label: "My video", content: sampleVideoContent())

        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.id == added.id)
        #expect(persistence.stored.count == 1)
        #expect(persistence.saveCount == 1)
    }

    @Test("add with empty/whitespace label falls back to defaultLabel")
    func emptyLabelUsesDefault() {
        let (store, _) = makeStore()
        let html = sampleHTMLContent("apple.com")
        let bookmark = store.add(label: "   ", content: html)
        #expect(bookmark.label == "apple.com")
    }

    @Test("add trims surrounding whitespace from custom label")
    func trimsWhitespace() {
        let (store, _) = makeStore()
        let bookmark = store.add(label: "  Beach Sunset  ", content: sampleVideoContent())
        #expect(bookmark.label == "Beach Sunset")
    }

    @Test("contains detects equivalent content regardless of label")
    func containsByContent() {
        let (store, _) = makeStore()
        let content = sampleVideoContent(byte: 0x42)
        store.add(label: "first", content: content)
        #expect(store.contains(content))
        #expect(!store.contains(sampleVideoContent(byte: 0x99)))
    }

    @Test("add can preserve Wallpaper Engine origin for scene bookmarks")
    func addPreservesWPEOriginForSceneBookmarks() {
        let (store, _) = makeStore()
        let content = sampleSceneContent()
        let origin = sampleWPEOrigin()

        let bookmark = store.add(
            label: "Scene",
            content: content,
            sourceDisplayName: "Bookmarked Scene",
            wpeOrigin: origin
        )

        #expect(bookmark.wpeOrigin == origin)
        #expect(store.bookmarks.first?.wpeOrigin == origin)
    }

    @Test("containsWPEBookmark matches by stored Wallpaper Engine origin")
    func containsWPEBookmarkByOrigin() {
        let (store, _) = makeStore()
        store.add(
            label: "Scene",
            content: sampleSceneContent(workshopID: "scene-origin"),
            sourceDisplayName: "Bookmarked Scene",
            wpeOrigin: sampleWPEOrigin(workshopID: "scene-origin")
        )

        #expect(store.containsWPEBookmark(workshopID: "scene-origin"))
        #expect(!store.containsWPEBookmark(workshopID: "other-scene"))
    }

    @Test("removeWPEBookmarks drops all matching workshop shortcuts and persists")
    func removeWPEBookmarksDropsMatchingWorkshopShortcuts() {
        let (store, persistence) = makeStore()
        store.add(
            label: "Origin-backed",
            content: sampleVideoContent(byte: 0x21),
            wpeOrigin: sampleWPEOrigin(workshopID: "shared-workshop")
        )
        store.add(
            label: "Scene descriptor backed",
            content: sampleSceneContent(workshopID: "shared-workshop"),
            wpeOrigin: nil
        )
        store.add(
            label: "Keep",
            content: sampleSceneContent(workshopID: "keep-workshop"),
            wpeOrigin: sampleWPEOrigin(workshopID: "keep-workshop")
        )
        let saveCountBeforeRemove = persistence.saveCount

        store.removeWPEBookmarks(workshopID: "shared-workshop")

        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.label == "Keep")
        #expect(persistence.stored.map(\.label) == ["Keep"])
        #expect(persistence.saveCount == saveCountBeforeRemove + 1)
    }

    @Test("WPE bookmark refresh CAS updates matching origin and web content only")
    func wpeBookmarkRefreshUpdatesOnlyMatchingOwner() throws {
        let original = Data("stale-bookmark-owner".utf8)
        let refreshed = Data("refreshed-bookmark-owner".utf8)
        let matchingOrigin = sampleWPEOrigin(
            workshopID: "refresh-me",
            bookmark: original
        )
        let matching = WallpaperBookmark(
            label: "Refresh me",
            content: .html(
                source: .folder(bookmarkData: original, indexFileName: "index.html"),
                config: .default
            ),
            sourceDisplayName: "Refresh me",
            wpeOrigin: matchingOrigin
        )
        let unrelated = WallpaperBookmark(
            label: "Leave me",
            content: sampleSceneContent(workshopID: "leave-me"),
            sourceDisplayName: "Leave me",
            wpeOrigin: sampleWPEOrigin(workshopID: "leave-me", bookmark: original)
        )
        let (store, persistence) = makeStore(seed: [matching, unrelated])
        let saveCountBefore = persistence.saveCount

        #expect(store.replaceWPEOriginBookmark(
            workshopID: "refresh-me",
            matching: original,
            with: refreshed
        ))

        let updated = try #require(store.bookmarks.first(where: { $0.label == "Refresh me" }))
        #expect(updated.wpeOrigin?.sourceFolderBookmark == refreshed)
        #expect(
            updated.content
                == .html(
                    source: .folder(bookmarkData: refreshed, indexFileName: "index.html"),
                    config: .default
                )
        )
        #expect(store.bookmarks.first(where: { $0.label == "Leave me" }) == unrelated)
        #expect(persistence.stored == store.bookmarks)
        #expect(persistence.saveCount == saveCountBefore + 1)
    }

    @Test("WPE bookmark refresh CAS rejects a newer re-grant without writing")
    func wpeBookmarkRefreshRejectsRegrant() {
        let original = Data("stale-bookmark-owner".utf8)
        let newer = Data("new-user-grant".utf8)
        let seed = WallpaperBookmark(
            label: "New grant",
            content: sampleSceneContent(workshopID: "refresh-me"),
            sourceDisplayName: "New grant",
            wpeOrigin: sampleWPEOrigin(workshopID: "refresh-me", bookmark: newer)
        )
        let (store, persistence) = makeStore(seed: [seed])
        let saveCountBefore = persistence.saveCount

        #expect(!store.replaceWPEOriginBookmark(
            workshopID: "refresh-me",
            matching: original,
            with: Data("late-refresh".utf8)
        ))
        #expect(store.bookmarks == [seed])
        #expect(persistence.stored == [seed])
        #expect(persistence.saveCount == saveCountBefore)
    }

    @Test("Local HTML refresh CAS survives reload and can be reapplied")
    func htmlBookmarkRefreshSurvivesReloadAndReapply() throws {
        let original = Data("stale-html-shortcut".utf8)
        let refreshed = Data("refreshed-html-shortcut".utf8)
        let seed = WallpaperBookmark(
            label: "Local dashboard",
            content: .html(
                source: .folder(bookmarkData: original, indexFileName: "index.html"),
                config: .default
            )
        )
        let persistence = InMemoryBookmarkPersistence()
        persistence.stored = [seed]
        let store = BookmarkStore(persistence: persistence)

        #expect(store.replaceHTMLBookmark(
            id: seed.id,
            matching: original,
            with: refreshed
        ))

        let reloaded = BookmarkStore(persistence: persistence)
        let reapplied = try #require(reloaded.bookmarks.first)
        #expect(
            reapplied.content
                == .html(
                    source: .folder(bookmarkData: refreshed, indexFileName: "index.html"),
                    config: .default
                )
        )
    }

    @Test("Local HTML refresh CAS rejects re-grant and leaves unrelated shortcut unchanged")
    func htmlBookmarkRefreshRejectsRegrantAndUnrelatedOwner() {
        let original = Data("stale-html-shortcut".utf8)
        let newerGrant = Data("new-html-grant".utf8)
        let target = WallpaperBookmark(
            label: "Re-granted",
            content: .html(source: .file(bookmarkData: newerGrant), config: .default)
        )
        let unrelated = WallpaperBookmark(
            label: "Unrelated",
            content: .html(source: .file(bookmarkData: original), config: .default)
        )
        let (store, persistence) = makeStore(seed: [target, unrelated])
        let saveCountBefore = persistence.saveCount

        #expect(!store.replaceHTMLBookmark(
            id: target.id,
            matching: original,
            with: Data("late-refresh".utf8)
        ))
        #expect(store.bookmarks == [target, unrelated])
        #expect(persistence.saveCount == saveCountBefore)
    }

    @Test("remove drops the matching id and persists")
    func removeMatchingID() {
        let (store, persistence) = makeStore()
        let a = store.add(label: "A", content: sampleVideoContent(byte: 0x01))
        _ = store.add(label: "B", content: sampleVideoContent(byte: 0x02))
        let saveCountBefore = persistence.saveCount

        store.remove(a.id)

        #expect(store.bookmarks.count == 1)
        #expect(store.bookmarks.first?.label == "B")
        #expect(persistence.saveCount == saveCountBefore + 1)
    }

    @Test("remove with unknown id is a no-op (still persists harmlessly)")
    func removeUnknownID() {
        let (store, _) = makeStore()
        store.add(label: "A", content: sampleVideoContent())
        store.remove(UUID())
        #expect(store.bookmarks.count == 1)
    }

    @Test("rename trims and applies new label")
    func renameTrimsAndApplies() {
        let (store, _) = makeStore()
        let bookmark = store.add(label: "Old", content: sampleVideoContent())
        store.rename(bookmark.id, to: "  New Name  ")
        #expect(store.bookmarks.first?.label == "New Name")
    }

    @Test("rename rejects empty / whitespace-only label")
    func renameRejectsEmpty() {
        let (store, _) = makeStore()
        let bookmark = store.add(label: "Original", content: sampleVideoContent())
        store.rename(bookmark.id, to: "   ")
        #expect(store.bookmarks.first?.label == "Original")
    }

    @Test("rename with unknown id is a no-op")
    func renameUnknownID() {
        let (store, _) = makeStore()
        let bookmark = store.add(label: "Keep", content: sampleVideoContent())
        store.rename(UUID(), to: "Should-Not-Apply")
        #expect(store.bookmarks.first?.label == "Keep")
        #expect(store.bookmarks.first?.id == bookmark.id)
    }

    @Test("Persistence load+save round-trips through fresh stores")
    func persistenceRoundTrip() {
        let persistence = InMemoryBookmarkPersistence()
        let store1 = BookmarkStore(persistence: persistence)
        store1.add(label: "Saved", content: sampleVideoContent(byte: 0xAA))

        let store2 = BookmarkStore(persistence: persistence)
        #expect(store2.bookmarks.count == 1)
        #expect(store2.bookmarks.first?.label == "Saved")
    }

    @Test("defaultLabel: video resolves to bookmark name fallback when unresolvable")
    func defaultLabelVideoFallback() {
        let label = BookmarkStore.defaultLabel(for: .video(bookmarkData: Data()))
        #expect(label == "Video")
    }

    @Test("defaultLabel: html .url uses host")
    func defaultLabelHTMLURL() {
        let label = BookmarkStore.defaultLabel(
            for: .html(source: .url(URL(string: "https://shadertoy.com/view/abc")!), config: .default)
        )
        #expect(label == "shadertoy.com")
    }

    @Test("defaultLabel: html .inline uses generic name")
    func defaultLabelHTMLInline() {
        let label = BookmarkStore.defaultLabel(
            for: .html(source: .inline("<html></html>"), config: .default)
        )
        #expect(label == "Inline web content")
    }

    @Test("defaultLabel: shader uses preset rawValue")
    func defaultLabelShader() {
        let label = BookmarkStore.defaultLabel(for: .metalShader(.aurora))
        #expect(label == "Aurora")
    }
}

// MARK: - WallpaperBookmark Codable round-trip

@Suite("WallpaperBookmark Codable")
struct WallpaperBookmarkCodableTests {

    private func roundTrip(_ bookmark: WallpaperBookmark) throws -> WallpaperBookmark {
        let data = try JSONEncoder().encode(bookmark)
        return try JSONDecoder().decode(WallpaperBookmark.self, from: data)
    }

    @Test("video bookmark round-trips with bookmark data")
    func videoRoundTrip() throws {
        let original = WallpaperBookmark(
            label: "Demo",
            content: .video(bookmarkData: Data([0x01, 0x02, 0x03]))
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test("html .url bookmark round-trips")
    func htmlURLRoundTrip() throws {
        let original = WallpaperBookmark(
            label: "Shader",
            content: .html(source: .url(URL(string: "https://shadertoy.com/view/MdX")!), config: .default)
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test("html .inline bookmark round-trips with custom config")
    func htmlInlineRoundTrip() throws {
        let custom = HTMLConfig(
            allowJavaScript: false,
            allowMouseInteraction: true,
            blockTrackers: false,
            customCSS: "body { background: black; }"
        )
        let original = WallpaperBookmark(
            label: "My HTML",
            content: .html(source: .inline("<h1>Hi</h1>"), config: custom)
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.content.htmlConfig == custom)
    }

    @Test("html .file bookmark round-trips")
    func htmlFileRoundTrip() throws {
        let original = WallpaperBookmark(
            label: "Local file",
            content: .html(source: .file(bookmarkData: Data([0xAB, 0xCD])), config: .default)
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test("html .folder bookmark round-trips with index file")
    func htmlFolderRoundTrip() throws {
        let original = WallpaperBookmark(
            label: "Site",
            content: .html(
                source: .folder(bookmarkData: Data([0x10]), indexFileName: "index.htm"),
                config: .default
            )
        )
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test("shader bookmark round-trips with preset")
    func shaderRoundTrip() throws {
        let original = WallpaperBookmark(label: "Plasma", content: .metalShader(.plasma))
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.content.shaderPreset == .plasma)
    }

    @Test("Wallpaper Engine scene bookmark round-trips with origin metadata")
    func sceneBookmarkRoundTripsWithOrigin() throws {
        let descriptor = SceneDescriptor(
            workshopID: "scene-origin",
            cacheRelativePath: "wpe-cache/scene-origin",
            entryFile: "scene.json",
            capabilityTier: .degraded,
            dependencyWorkshopIDs: ["123456789012"]
        )
        let origin = WPEOrigin(
            workshopID: "scene-origin",
            title: "Origin Scene",
            originalType: .scene,
            sourceFolderBookmark: Data([0x01, 0x02]),
            cacheRelativePath: "wpe-cache/scene-origin",
            previewFileName: "preview.png",
            entryFile: "scene.json",
            resourceLocation: .cache,
            dependencyWorkshopIDs: ["123456789012"]
        )
        let original = WallpaperBookmark(
            label: "Origin Scene",
            content: .scene(descriptor),
            sourceDisplayName: "Origin Scene",
            wpeOrigin: origin
        )

        let decoded = try roundTrip(original)

        #expect(decoded == original)
        #expect(decoded.wpeOrigin == origin)
    }

    @Test("Array of mixed bookmarks round-trips and preserves order")
    func arrayOrderPreserved() throws {
        let bookmarks = [
            WallpaperBookmark(label: "One", content: .video(bookmarkData: Data([0x01]))),
            WallpaperBookmark(label: "Two", content: .html(source: .url(URL(string: "https://a.com")!), config: .default)),
            WallpaperBookmark(label: "Three", content: .metalShader(.waves)),
        ]
        let data = try JSONEncoder().encode(bookmarks)
        let decoded = try JSONDecoder().decode([WallpaperBookmark].self, from: data)

        #expect(decoded.count == 3)
        #expect(decoded.map(\.label) == ["One", "Two", "Three"])
        #expect(decoded == bookmarks)
    }

    @Test("Identifier survives Codable so SwiftUI ForEach IDs stay stable")
    func idStable() throws {
        let original = WallpaperBookmark(label: "Stable", content: .metalShader(.gradient))
        let decoded = try roundTrip(original)
        #expect(decoded.id == original.id)
    }
}
