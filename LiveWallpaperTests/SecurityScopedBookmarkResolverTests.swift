import Foundation
import Testing
@testable import LiveWallpaper

struct SecurityScopedBookmarkResolverTests {

    private static let fixtureURL = URL(fileURLWithPath: "/tmp/livewallpaper-test-bookmark-fixture")
    private static let originalData = Data("original".utf8)
    private static let refreshedData = Data("refreshed".utf8)

    @Test("Returns .missing when no data is stored")
    func missingData() {
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (Self.fixtureURL, false) },
            refreshData: { _ in Self.refreshedData }
        )
        let target = SecurityScopedBookmarkResolver.Target(label: "test")

        let result = resolver.resolve(nil, target: target)
        guard case .failure(.missing) = result else {
            Issue.record("Expected .missing for nil data, got \(result)")
            return
        }
    }

    @Test("Fresh bookmark resolves without refresh and never invokes save")
    func freshBookmark() {
        let capture = SaveCapture()
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (Self.fixtureURL, false) },
            refreshData: { _ in Self.refreshedData }
        )
        let target = SecurityScopedBookmarkResolver.Target(label: "test", save: capture.save)

        let result = resolver.resolve(Self.originalData, target: target)

        guard case .success(let resolved) = result else {
            Issue.record("Expected .success, got \(result)")
            return
        }
        #expect(resolved.url == Self.fixtureURL)
        #expect(resolved.bookmarkData == Self.originalData)
        #expect(resolved.didRefresh == false)
        #expect(capture.snapshot.isEmpty, "save must not be invoked when bookmark is fresh")
    }

    @Test("Stale bookmark refreshes and invokes the target's save closure")
    func staleBookmarkRefreshes() {
        let capture = SaveCapture()
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (Self.fixtureURL, true) },
            refreshData: { _ in Self.refreshedData }
        )
        let target = SecurityScopedBookmarkResolver.Target(label: "test", save: capture.save)

        let result = resolver.resolve(Self.originalData, target: target)

        guard case .success(let resolved) = result else {
            Issue.record("Expected .success on stale resolve, got \(result)")
            return
        }
        #expect(resolved.didRefresh == true)
        #expect(resolved.bookmarkData == Self.refreshedData, "must return refreshed data to in-process callers")
        #expect(capture.snapshot == [Self.refreshedData])
    }

    @Test("Stale + refresh failure preserves grace-use semantics")
    func staleRefreshFailure() {
        let capture = SaveCapture()
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in (Self.fixtureURL, true) },
            refreshData: { _ in throw FakeError.refreshFailed }
        )
        let target = SecurityScopedBookmarkResolver.Target(label: "test", save: capture.save)

        let result = resolver.resolve(Self.originalData, target: target)

        guard case .success(let resolved) = result else {
            Issue.record("Expected .success even when refresh fails, got \(result)")
            return
        }
        #expect(resolved.url == Self.fixtureURL)
        #expect(resolved.bookmarkData == Self.originalData, "must return current data for grace use")
        #expect(resolved.didRefresh == false, "refresh that threw must not flip didRefresh")
        #expect(capture.snapshot.isEmpty, "failed refresh must not invoke save")
    }

    @Test("Resolution throw propagates as .resolutionFailed")
    func resolutionThrowsPropagates() {
        let capture = SaveCapture()
        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { _ in throw FakeError.resolutionFailed },
            refreshData: { _ in Self.refreshedData }
        )
        let target = SecurityScopedBookmarkResolver.Target(label: "test", save: capture.save)

        let result = resolver.resolve(Self.originalData, target: target)

        guard case .failure(.resolutionFailed) = result else {
            Issue.record("Expected .resolutionFailed, got \(result)")
            return
        }
        #expect(capture.snapshot.isEmpty)
    }

    @Test("withScopedAccess runs the closure")
    func withScopedAccessRunsWork() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var ranWith: Bool?
        SecurityScopedBookmarkResolver.withScopedAccess(tempURL) { didStart in
            ranWith = didStart
        }
        #expect(ranWith != nil, "work closure must run regardless of scope outcome")
    }

    @Test("withScopedAccess rethrows but still runs work to completion")
    func withScopedAccessRethrows() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        var didReach = false
        do {
            try SecurityScopedBookmarkResolver.withScopedAccess(tempURL) { _ in
                didReach = true
                throw FakeError.refreshFailed
            }
            Issue.record("Expected rethrow, work returned normally")
        } catch FakeError.refreshFailed {
            #expect(didReach)
        } catch {
            Issue.record("Wrong error rethrown: \(error)")
        }
    }
}

private enum FakeError: Error {
    case resolutionFailed
    case refreshFailed
}

/// Thread-safe accumulator for test save-side-effect assertions.
private final class SaveCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [Data] = []

    var snapshot: [Data] {
        lock.lock(); defer { lock.unlock() }
        return saved
    }

    var save: @Sendable (_ original: Data, _ refreshed: Data) -> Void {
        { [weak self] _, refreshed in
            guard let self else { return }
            self.lock.lock()
            self.saved.append(refreshed)
            self.lock.unlock()
        }
    }
}
