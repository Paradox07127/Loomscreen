import Foundation
import os

/// Lightweight launch-time update checker for the Loomscreen Lite SKU.
///
/// **Cadence**: once per launch, throttled by a persisted "next eligible"
/// instant — 12 h after a successful check, but only 1 h after a failed one so
/// a transient GitHub blip doesn't suppress the next check for the full window.
/// No background timer. Manual "Check for Updates" from the About panel
/// bypasses the throttle.
///
/// **Network**: single unauthenticated GET to GitHub's
/// `/repos/<owner>/<repo>/releases?per_page=10` with `Accept: application/vnd.github+json`.
/// No polling, no telemetry, no client identifier beyond `User-Agent`.
///
/// Compiles in both SKUs (Pro test runner covers it), but only Lite calls
/// `checkNow(force:)` from `applicationDidFinishLaunching` (`#if LITE_BUILD`).
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
    /// Truthful time of the last check attempt — surfaced in the UI as
    /// "Last checked …", so it always reflects when we actually reached out,
    /// regardless of outcome.
    private(set) var lastCheckedAt: Date?

    /// Earliest instant an automatic check may run again. Advanced by
    /// `throttleInterval` on success and `failureRetryInterval` on failure.
    /// Kept separate from `lastCheckedAt` so the shorter failure backoff
    /// never corrupts the user-visible timestamp.
    private var nextEligibleAt: Date?

    /// Tag the user pressed "Skip this version" against. Suppresses the
    /// banner for that exact tag; a newer tag still triggers as normal.
    var skippedVersionTag: String? {
        get { Self.defaults.string(forKey: Self.skippedVersionKey) }
        set { Self.defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    static let releasesAPI = URL(
        string: "https://api.github.com/repos/Paradox07127/Loomscreen/releases?per_page=10"
    ) ?? URL(fileURLWithPath: "/")
    static let releasesPage = URL(
        string: "https://github.com/Paradox07127/Loomscreen/releases"
    ) ?? URL(fileURLWithPath: "/")

    static let tagPrefix = "loomscreen-v"
    static let throttleInterval: TimeInterval = 60 * 60 * 12
    /// Backoff after a failed check (network error, rate limit, bad payload).
    /// Far shorter than `throttleInterval` so a transient GitHub blip doesn't
    /// suppress the next automatic check for the full 12 h, while still keeping
    /// a floor that prevents a retry storm on every relaunch.
    static let failureRetryInterval: TimeInterval = 60 * 60
    static let maximumReleaseBodyCharacters = 4_000
    static let trustedGitHubHost = "github.com"
    static let trustedReleasesPathPrefix = "/Paradox07127/Loomscreen/releases/"
    static let trustedDownloadPathPrefix = "/Paradox07127/Loomscreen/releases/download/"

    private static let lastCheckedKey = "loomscreen.update.lastCheckedAt"
    private static let nextEligibleKey = "loomscreen.update.nextEligibleAt"
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
        if let nextEligible = Self.defaults.object(forKey: Self.nextEligibleKey) as? Date {
            self.nextEligibleAt = nextEligible
        } else if let stored = self.lastCheckedAt {
            // Upgrade path: installs that predate the split still honor the
            // 12 h window off their recorded last-checked time.
            self.nextEligibleAt = stored.addingTimeInterval(Self.throttleInterval)
        }
    }

    /// Run a check. `force = false` honors the throttle window; `force = true`
    /// (manual "Check for Updates" button) ignores it. A successful check pushes
    /// the next eligible time out 12 h; a failure (no network, rate-limited,
    /// malformed payload) pushes it only 1 h, so a transient error doesn't
    /// suppress automatic checks for the full window yet still can't trigger a
    /// retry storm on every relaunch.
    func checkNow(force: Bool) async {
        guard status != .checking else { return }
        let attemptedAt = now()
        if !force, let eligible = nextEligibleAt {
            let remaining = eligible.timeIntervalSince(attemptedAt)
            // Clock-rollback detectors: an attempt timestamped before the last
            // recorded one, or a wait longer than we ever schedule. Either way
            // run the check instead of extending the suppression.
            let rolledBack = lastCheckedAt.map { attemptedAt < $0 } ?? false
            if !rolledBack, remaining > 0, remaining <= Self.throttleInterval {
                logger.debug("Skipping update check (throttle window not elapsed).")
                return
            }
        }
        status = .checking
        recordLastChecked(attemptedAt)
        do {
            let releases = try await transport.fetchReleases(from: Self.releasesAPI)
            status = evaluate(releases: releases)
            scheduleNextEligible(after: Self.throttleInterval, from: attemptedAt)
        } catch {
            // Generic user-facing string so a hostile response can't smuggle
            // implementation details into the UI.
            logger.error("Update check failed: \(String(describing: error), privacy: .private)")
            status = .failed(reason: "Unable to check for updates right now.")
            scheduleNextEligible(after: Self.failureRetryInterval, from: attemptedAt)
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

    private func recordLastChecked(_ stamp: Date) {
        lastCheckedAt = stamp
        Self.defaults.set(stamp, forKey: Self.lastCheckedKey)
    }

    private func scheduleNextEligible(after interval: TimeInterval, from stamp: Date) {
        let next = stamp.addingTimeInterval(interval)
        nextEligibleAt = next
        Self.defaults.set(next, forKey: Self.nextEligibleKey)
    }

    private func evaluate(releases: [GitHubRelease]) -> Status {
        let candidates: [LatestRelease] = releases.compactMap { release in
            guard !release.draft, !release.prerelease else { return nil }
            guard release.tagName.hasPrefix(Self.tagPrefix) else { return nil }
            guard let version = SemanticVersion(parsing: release.tagName) else { return nil }
            return LatestRelease(
                tagName: release.tagName,
                version: version,
                releasePageURL: Self.trustedReleasePageURL(release.htmlURL),
                downloadURL: release.assets.compactMap(Self.trustedDMGDownloadURL).first,
                publishedAt: release.publishedAt,
                body: release.body.map { String($0.prefix(Self.maximumReleaseBodyCharacters)) } ?? ""
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

    /// Returns the GitHub-Releases URL we trust to open in the user's
    /// browser. Anything else (a hostile mirror redirected through
    /// `html_url`, a custom URL scheme, an http:// host swap) falls back
    /// to the canonical releases page so we never hand `NSWorkspace.open`
    /// an attacker-controlled destination.
    private static func trustedReleasePageURL(_ url: URL?) -> URL {
        guard let url, isTrustedGitHubURL(url, pathPrefix: trustedReleasesPathPrefix)
        else { return releasesPage }
        return url
    }

    private static func trustedDMGDownloadURL(for asset: GitHubRelease.Asset) -> URL? {
        // A unified release carries both the Lite (`Loomscreen-*.dmg`) and Pro
        // (`Loomscreen-Pro-*.dmg`) builds; the Lite updater must resolve its own
        // DMG, never the Pro one — match the Lite name and exclude the Pro one
        // regardless of the asset order GitHub returns.
        let name = asset.name.lowercased()
        guard name.hasPrefix("loomscreen-"), !name.contains("-pro-"), name.hasSuffix(".dmg"),
              let url = asset.browserDownloadURL,
              isTrustedGitHubURL(url, pathPrefix: trustedDownloadPathPrefix),
              url.pathExtension.lowercased() == "dmg"
        else { return nil }
        return url
    }

    private static func isTrustedGitHubURL(_ url: URL, pathPrefix: String) -> Bool {
        let standardized = url.standardized
        return standardized.scheme?.lowercased() == "https"
            && standardized.host?.lowercased() == trustedGitHubHost
            && standardized.path.hasPrefix(pathPrefix)
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
/// and ISO 8601 date decoding. Refuses any response that does not arrive
/// from the canonical GitHub host or that exceeds the size cap — both
/// defenses against a hostile or compromised origin.
struct URLSessionUpdateCheckerTransport: UpdateCheckerTransport {
    private let session: URLSession

    static let maximumResponseBytes = 512 * 1024
    static let requestTimeoutSeconds: TimeInterval = 15

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            self.session = URLSession(configuration: config, delegate: RedirectBlocker(), delegateQueue: nil)
        }
    }

    func fetchReleases(from url: URL) async throws -> [GitHubRelease] {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Loomscreen-UpdateChecker", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == "api.github.com" else {
            // Response arrived from a host we did not address — reject
            // before decoding so a redirect-injected payload never reaches
            // the parser.
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("json") else {
            throw URLError(.cannotParseResponse)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let url = request.url,
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "api.github.com" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
