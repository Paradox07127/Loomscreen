import Foundation
import os

/// Lightweight launch-time update checker for the Loomscreen Lite SKU.
///
/// **Cadence policy.** Runs *once* per app launch, throttled to a minimum
/// 12-hour interval since the last check (persisted in `UserDefaults`).
/// There is no background timer: if the user opens Loomscreen ten times in a
/// row, only the first lookup actually hits GitHub. Manual `Check for
/// Updates` from the About panel bypasses the throttle.
///
/// **Network shape.** Single unauthenticated GET to
/// `https://api.github.com/repos/<owner>/<repo>/releases?per_page=10`,
/// `Accept: application/vnd.github+json`. GitHub's unauth quota is 60
/// requests/hour/IP; our worst case (one user, one launch / 12 h) is far
/// below that. We do not poll, do not transmit telemetry, do not include
/// any client identifier beyond a plain `User-Agent`.
///
/// **Pro is opt-out at the call site.** The class compiles in both SKUs so
/// the Pro test runner can cover it, but only the Loomscreen Lite app
/// invokes `checkNow(force:)` from its `applicationDidFinishLaunching`
/// hook (`#if LITE_BUILD`). Pro's update story is reserved for a future
/// Sparkle / Developer ID switch and uses different entitlements.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(LatestRelease)
        case failed(reason: String)
    }

    struct LatestRelease: Equatable, Sendable {
        let tagName: String
        let version: SemanticVersion
        let releasePageURL: URL
        let downloadURL: URL?
        let publishedAt: Date?
        let body: String
    }

    private(set) var status: Status = .idle
    private(set) var lastCheckedAt: Date?

    /// Tag the user pressed "Skip this version" against. Suppresses the
    /// banner for that exact tag; a newer tag still triggers as normal.
    var skippedVersionTag: String? {
        get { Self.defaults.string(forKey: Self.skippedVersionKey) }
        set { Self.defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    static let releasesAPI = URL(
        string: "https://api.github.com/repos/Paradox07127/LiveWallpaper/releases?per_page=10"
    )!
    static let releasesPage = URL(
        string: "https://github.com/Paradox07127/LiveWallpaper/releases"
    )!

    static let tagPrefix = "loomscreen-v"
    static let throttleInterval: TimeInterval = 60 * 60 * 12

    private static let lastCheckedKey = "loomscreen.update.lastCheckedAt"
    private static let skippedVersionKey = "loomscreen.update.skippedVersion"
    private static let defaults: UserDefaults = .standard

    private let logger = Logger(subsystem: "com.loomscreen", category: "UpdateChecker")
    private let transport: any UpdateCheckerTransport
    private let now: @Sendable () -> Date
    private let currentVersion: SemanticVersion

    init(
        transport: any UpdateCheckerTransport = URLSessionUpdateCheckerTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        currentVersionString: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    ) {
        self.transport = transport
        self.now = now
        self.currentVersion = SemanticVersion(parsing: currentVersionString ?? "0.0.0")
            ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        if let stored = Self.defaults.object(forKey: Self.lastCheckedKey) as? Date {
            self.lastCheckedAt = stored
        }
    }

    /// Run a check. `force = false` honors the 12 h throttle; `force = true`
    /// (manual "Check for Updates" button) ignores it.
    func checkNow(force: Bool) async {
        guard status != .checking else { return }
        if !force, let last = lastCheckedAt, now().timeIntervalSince(last) < Self.throttleInterval {
            logger.debug("Skipping update check (within 12h throttle).")
            return
        }
        status = .checking
        do {
            let releases = try await transport.fetchReleases(from: Self.releasesAPI)
            let timestamp = now()
            persistLastCheckedAt(timestamp)
            status = evaluate(releases: releases)
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(reason: error.localizedDescription)
        }
    }

    /// Mark the currently-available release as "skip this version" — the
    /// banner stays dismissed until a strictly newer tag appears.
    func skipCurrentAvailable() {
        if case .available(let release) = status {
            skippedVersionTag = release.tagName
            status = .upToDate
        }
    }

    private func persistLastCheckedAt(_ stamp: Date) {
        lastCheckedAt = stamp
        Self.defaults.set(stamp, forKey: Self.lastCheckedKey)
    }

    private func evaluate(releases: [GitHubRelease]) -> Status {
        let candidates: [LatestRelease] = releases.compactMap { release in
            guard !release.draft, !release.prerelease else { return nil }
            guard release.tagName.hasPrefix(Self.tagPrefix) else { return nil }
            guard let version = SemanticVersion(parsing: release.tagName) else { return nil }
            let download = release.assets
                .first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL
            return LatestRelease(
                tagName: release.tagName,
                version: version,
                releasePageURL: release.htmlURL ?? Self.releasesPage,
                downloadURL: download,
                publishedAt: release.publishedAt,
                body: release.body ?? ""
            )
        }

        guard let newest = candidates.max(by: { $0.version < $1.version }) else {
            logger.debug("No published Loomscreen releases yet.")
            return .upToDate
        }
        guard newest.version > currentVersion else {
            return .upToDate
        }
        if newest.tagName == skippedVersionTag {
            logger.debug("User has skipped \(newest.tagName, privacy: .public).")
            return .upToDate
        }
        return .available(newest)
    }
}

/// Pluggable network seam so unit tests can replay canned GitHub responses
/// without touching the real network.
protocol UpdateCheckerTransport: Sendable {
    func fetchReleases(from url: URL) async throws -> [GitHubRelease]
}

/// Subset of the GitHub Releases API we care about. Conforms to `Decodable`
/// so we can deserialize the response directly. Explicit `CodingKeys` carry
/// the snake-case GitHub keys instead of relying on `convertFromSnakeCase`,
/// which mangles acronym-cased properties (`html_url` → `htmlUrl`, not
/// `htmlURL`, so the optional silently decodes to `nil`).
struct GitHubRelease: Decodable, Sendable, Equatable {
    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let htmlURL: URL?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case assets
    }

    struct Asset: Decodable, Sendable, Equatable {
        let name: String
        let browserDownloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// Default transport: a vanilla `URLSession` GET with a `User-Agent`
/// (GitHub rejects requests with no UA), `Accept: application/vnd.github+json`,
/// and ISO 8601 date decoding.
struct URLSessionUpdateCheckerTransport: UpdateCheckerTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchReleases(from url: URL) async throws -> [GitHubRelease] {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Loomscreen-UpdateChecker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode)."
            ])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }
}
