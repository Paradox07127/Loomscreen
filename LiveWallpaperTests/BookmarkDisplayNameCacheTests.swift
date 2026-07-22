import Testing
import Foundation
import LiveWallpaperCore
import Observation
@testable import LiveWallpaper

@Suite("BookmarkDisplayNameCache")
@MainActor
struct BookmarkDisplayNameCacheTests {
    private let bookmarkA = Data("bookmark-A".utf8)
    private let bookmarkB = Data("bookmark-B".utf8)

    @Test("Round-trips records and reads names")
    func recordRoundtrip() {
        let cache = BookmarkDisplayNameCache()
        #expect(cache.name(for: bookmarkA) == nil)
        cache.record(bookmarkA, name: "wallpaper.mp4")
        #expect(cache.name(for: bookmarkA) == "wallpaper.mp4")
        #expect(cache.name(for: bookmarkB) == nil)
    }

    @Test("Whitespace / nil name clears the entry")
    func whitespaceClearsEntry() {
        let cache = BookmarkDisplayNameCache()
        cache.record(bookmarkA, name: "video.mov")
        cache.record(bookmarkA, name: "   ")
        #expect(cache.name(for: bookmarkA) == nil)
        cache.record(bookmarkA, name: "video.mov")
        cache.record(bookmarkA, name: nil)
        #expect(cache.name(for: bookmarkA) == nil)
    }

    @Test("Trims whitespace around the display name")
    func trimsWhitespace() {
        let cache = BookmarkDisplayNameCache()
        cache.record(bookmarkA, name: "  trim-me.mp4  \n")
        #expect(cache.name(for: bookmarkA) == "trim-me.mp4")
    }

    @Test("Empty Data is rejected — neither stored nor marked unresolved")
    func emptyBookmarkRejected() {
        let cache = BookmarkDisplayNameCache()
        let counter = ChangeCounter()
        withObservationTracking {
            _ = cache.name(for: Data())
        } onChange: {
            counter.increment()
        }
        cache.record(Data(), name: "should-not-store")
        #expect(cache.name(for: Data()) == nil)
        #expect(counter.value == 0)
    }

    @Test("record invalidates Observation for SwiftUI re-render")
    func recordInvalidatesObservation() {
        let cache = BookmarkDisplayNameCache()
        let counter = ChangeCounter()
        withObservationTracking {
            _ = cache.name(for: bookmarkA)
        } onChange: {
            counter.increment()
        }
        #expect(counter.value == 0)
        cache.record(bookmarkA, name: "first.mp4")
        #expect(counter.value == 1)
    }

    @Test("Clearing a known entry also invalidates Observation")
    func clearInvalidatesObservation() {
        let cache = BookmarkDisplayNameCache()
        cache.record(bookmarkA, name: "video.mp4")
        let counter = ChangeCounter()
        withObservationTracking {
            _ = cache.name(for: bookmarkA)
        } onChange: {
            counter.increment()
        }
        cache.record(bookmarkA, name: nil)
        #expect(counter.value == 1)
    }

    @Test("resolveIfNeeded is idempotent — same bookmark resolved once")
    func resolveIfNeededIsIdempotent() {
        let cache = BookmarkDisplayNameCache()
        cache.resolveIfNeeded(bookmarkA)
        #expect(cache.name(for: bookmarkA) == nil)
        cache.record(bookmarkA, name: "manual.mp4")
        cache.resolveIfNeeded(bookmarkA)
        #expect(cache.name(for: bookmarkA) == "manual.mp4")
    }

    @Test("prime(bookmarks:) skips empty entries and resolves the rest once")
    func primeSkipsEmptyAndResolvesRest() {
        let cache = BookmarkDisplayNameCache()
        cache.record(bookmarkA, name: "kept.mp4")
        cache.prime(bookmarks: [bookmarkA, bookmarkB, Data()])
        #expect(cache.name(for: bookmarkA) == "kept.mp4")
        #expect(cache.name(for: bookmarkB) == nil)
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
