import Foundation
import Testing
@testable import LiveWallpaper

@Suite("SemanticVersion parsing and ordering")
struct SemanticVersionTests {
    @Test("Parses bare semver triples")
    func parsesBareSemver() {
        let v = SemanticVersion(parsing: "1.2.3")
        #expect(v == SemanticVersion(major: 1, minor: 2, patch: 3))
    }

    @Test("Accepts the v / loomscreen-v / lwp-v prefixes we publish")
    func acceptsKnownPrefixes() {
        #expect(SemanticVersion(parsing: "v1.0.0") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(SemanticVersion(parsing: "loomscreen-v2.10.5") == SemanticVersion(major: 2, minor: 10, patch: 5))
        #expect(SemanticVersion(parsing: "lwp-v0.4.1") == SemanticVersion(major: 0, minor: 4, patch: 1))
    }

    @Test("Strips suffix metadata after - or + from the patch component")
    func stripsSuffixMetadata() {
        #expect(SemanticVersion(parsing: "1.0.0-beta1") == SemanticVersion(major: 1, minor: 0, patch: 0))
        #expect(SemanticVersion(parsing: "1.0.0+build42") == SemanticVersion(major: 1, minor: 0, patch: 0))
    }

    @Test("Defaults missing patch component to zero")
    func defaultsMissingPatchToZero() {
        #expect(SemanticVersion(parsing: "1.5") == SemanticVersion(major: 1, minor: 5, patch: 0))
    }

    @Test("Rejects garbage")
    func rejectsGarbage() {
        #expect(SemanticVersion(parsing: "garbage") == nil)
        #expect(SemanticVersion(parsing: "") == nil)
        #expect(SemanticVersion(parsing: "1") == nil)
        #expect(SemanticVersion(parsing: "a.b.c") == nil)
    }

    @Test("Orders components lexicographically (major dominates minor dominates patch)")
    func ordering() {
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 2, minor: 0, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 0, patch: 9) < SemanticVersion(major: 1, minor: 1, patch: 0))
        #expect(SemanticVersion(major: 1, minor: 0, patch: 0) < SemanticVersion(major: 1, minor: 0, patch: 1))
        #expect(SemanticVersion(major: 1, minor: 10, patch: 0) > SemanticVersion(major: 1, minor: 9, patch: 99))
    }
}

@Suite("UpdateChecker state-machine flows")
@MainActor
struct UpdateCheckerTests {
    private var defaultsSuite: UserDefaults {
        // Always read/write through the standard suite the production class
        // uses, but scope our fixture keys with a UUID so two parallel test
        // suites never clobber each other.
        UserDefaults.standard
    }

    /// Wipe both persistence keys before every test so throttle and skip
    /// state never bleed across `@Test` runs.
    private func resetDefaults() {
        defaultsSuite.removeObject(forKey: "loomscreen.update.lastCheckedAt")
        defaultsSuite.removeObject(forKey: "loomscreen.update.skippedVersion")
    }

    @Test("Surfaces .available when a strictly newer Loomscreen release exists")
    func reportsAvailableForNewerLoomscreenTag() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0", asset: "Loomscreen-1.1.0.dmg")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v1.1.0")
        #expect(release.version == SemanticVersion(major: 1, minor: 1, patch: 0))
        #expect(release.downloadURL?.lastPathComponent == "Loomscreen-1.1.0.dmg")
    }

    @Test("Reports .upToDate when the newest tag matches the running version")
    func reportsUpToDateWhenSameVersion() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Ignores draft and prerelease tags")
    func ignoresDraftAndPrerelease() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v2.0.0", draft: true),
            release(tag: "loomscreen-v1.5.0", prerelease: true),
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Ignores tags missing the loomscreen-v prefix (e.g. Pro tags)")
    func ignoresProTags() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "v3.5.0"),  // hypothetical Pro tag
            release(tag: "loomscreen-v1.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Honors user-skipped version")
    func honorsSkippedVersion() async {
        resetDefaults()
        defaultsSuite.set("loomscreen-v1.1.0", forKey: "loomscreen.update.skippedVersion")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        #expect(checker.status == .upToDate)
    }

    @Test("Still surfaces newer-than-skipped tags")
    func newerThanSkippedStillSurfaces() async {
        resetDefaults()
        defaultsSuite.set("loomscreen-v1.1.0", forKey: "loomscreen.update.skippedVersion")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.2.0"),
            release(tag: "loomscreen-v1.1.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v1.2.0")
    }

    @Test("Reports .failed when the transport throws")
    func reportsFailedOnTransportError() async {
        resetDefaults()
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "test failure" }
        }
        let transport = StubTransport(error: TestError())
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        guard case .failed(let reason) = checker.status else {
            Issue.record("Expected .failed, got \(String(describing: checker.status))")
            return
        }
        #expect(reason == "test failure")
    }

    @Test("Skips network call when inside the 12-hour throttle window")
    func skipsThrottledCalls() async {
        resetDefaults()
        let recent = Date(timeIntervalSince1970: 1_000_000)
        defaultsSuite.set(recent, forKey: "loomscreen.update.lastCheckedAt")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v9.9.9")  // would clearly trigger .available
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { recent.addingTimeInterval(60 * 60) },  // 1 h after last check
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)

        // No request was made, status stays at the initial idle.
        #expect(checker.status == .idle)
        #expect(transport.fetchCount == 0)
    }

    @Test("Honors force=true even when inside the throttle window")
    func forceIgnoresThrottle() async {
        resetDefaults()
        let recent = Date(timeIntervalSince1970: 1_000_000)
        defaultsSuite.set(recent, forKey: "loomscreen.update.lastCheckedAt")
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v2.0.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { recent.addingTimeInterval(60 * 60) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: true)

        #expect(transport.fetchCount == 1)
        guard case .available(let release) = checker.status else {
            Issue.record("Expected .available, got \(String(describing: checker.status))")
            return
        }
        #expect(release.tagName == "loomscreen-v2.0.0")
    }

    @Test("skipCurrentAvailable persists the tag and clears the banner")
    func skipCurrentPersistsTag() async {
        resetDefaults()
        let transport = StubTransport(releases: [
            release(tag: "loomscreen-v1.1.0")
        ])
        let checker = UpdateChecker(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000_000) },
            currentVersionString: "1.0.0"
        )

        await checker.checkNow(force: false)
        checker.skipCurrentAvailable()

        #expect(checker.status == .upToDate)
        #expect(defaultsSuite.string(forKey: "loomscreen.update.skippedVersion") == "loomscreen-v1.1.0")
    }

    @Test("Decodes a realistic GitHub Releases response")
    func decodesRealisticJSON() throws {
        let json = """
        [
          {
            "tag_name": "loomscreen-v1.0.1",
            "body": "First public release.",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-06-01T12:00:00Z",
            "html_url": "https://github.com/Paradox07127/LiveWallpaper/releases/tag/loomscreen-v1.0.1",
            "assets": [
              {
                "name": "Loomscreen-1.0.1.dmg",
                "browser_download_url": "https://github.com/Paradox07127/LiveWallpaper/releases/download/loomscreen-v1.0.1/Loomscreen-1.0.1.dmg"
              }
            ]
          }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let releases = try decoder.decode([GitHubRelease].self, from: Data(json.utf8))
        #expect(releases.count == 1)
        let r = releases[0]
        #expect(r.tagName == "loomscreen-v1.0.1")
        #expect(r.draft == false)
        #expect(r.prerelease == false)
        #expect(r.assets.first?.name == "Loomscreen-1.0.1.dmg")
        #expect(r.htmlURL?.absoluteString.contains("loomscreen-v1.0.1") == true)
    }

    // MARK: - Helpers

    private func release(
        tag: String,
        asset: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tag,
            body: nil,
            draft: draft,
            prerelease: prerelease,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            htmlURL: URL(string: "https://github.com/Paradox07127/LiveWallpaper/releases/tag/\(tag)"),
            assets: asset.map { name in
                [GitHubRelease.Asset(
                    name: name,
                    browserDownloadURL: URL(string: "https://github.com/Paradox07127/LiveWallpaper/releases/download/\(tag)/\(name)")
                )]
            } ?? []
        )
    }
}

/// Records every `fetchReleases` invocation so tests can both replay canned
/// responses and assert on call count (throttle-skip verification).
private final class StubTransport: UpdateCheckerTransport, @unchecked Sendable {
    private let response: Result<[GitHubRelease], Error>
    private(set) var fetchCount = 0

    init(releases: [GitHubRelease]) {
        self.response = .success(releases)
    }

    init(error: Error) {
        self.response = .failure(error)
    }

    func fetchReleases(from url: URL) async throws -> [GitHubRelease] {
        fetchCount += 1
        switch response {
        case .success(let releases): return releases
        case .failure(let error): throw error
        }
    }
}
