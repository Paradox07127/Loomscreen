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
        #expect(label == "Inline HTML")
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
