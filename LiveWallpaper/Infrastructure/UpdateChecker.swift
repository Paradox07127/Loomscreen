import Foundation
import os

/// Lightweight launch-time update checker for the Loomscreen Lite SKU.
///
/// **Cadence**: once per launch, ≥12h since last check (persisted in
/// `UserDefaults`); no background timer. Manual "Check for Updates" from the
/// About panel bypasses the throttle.
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
    private(set) var lastCheckedAt: Date?

    /// Tag the user pressed "Skip this version" against. Suppresses the
    /// banner for that exact tag; a newer tag still triggers as normal.
    var skippedVersionTag: String? {
        get { Self.defaults.string(forKey: Self.skippedVersionKey) }
        set { Self.defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    static let releasesAPI = URL(
        string: "https://api.github.com/repos/Paradox07127/Loomscreen/releases?per_page=10"
    )!
    static let releasesPage = URL(
        string: "https://github.com/Paradox07127/Loomscreen/releases"
    )!

    static let tagPrefix = "loomscreen-v"
    static let throttleInterval: TimeInterval = 60 * 60 * 12
    static let maximumReleaseBodyCharacters = 4_000
    static let trustedGitHubHost = "github.com"
    static let trustedReleasesPathPrefix = "/Paradox07127/Loomscreen/releases/"
    static let trustedDownloadPathPrefix = "/Paradox07127/Loomscreen/releases/download/"

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
    /// (manual "Check for Updates" button) ignores it. The attempt timestamp
    /// is persisted *before* the network call so a failed lookup (no
    /// network, rate-limited, malformed payload) cannot reset the throttle
    /// and trigger a retry on every relaunch.
    func checkNow(force: Bool) async {
        guard status != .checking else { return }
        let attemptedAt = now()
        if !force, let last = lastCheckedAt {
            let elapsed = attemptedAt.timeIntervalSince(last)
            // Negative `elapsed` = wall-clock moved backwards (timezone change,
            // NTP correction); treat as stale rather than suppressing forever.
            if elapsed >= 0, elapsed < Self.throttleInterval {
                logger.debug("Skipping update check (within 12h throttle).")
                return
            }
        }
        status = .checking
        persistLastCheckedAt(attemptedAt)
        do {
            let releases = try await transport.fetchReleases(from: Self.releasesAPI)
            status = evaluate(releases: releases)
        } catch {
            // Generic user-facing string so a hostile response can't smuggle
            // implementation details into the UI.
            logger.error("Update check failed: \(String(describing: error), privacy: .private)")
            status = .failed(reason: "Unable to check for updates right now.")
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
        guard asset.name.lowercased().hasSuffix(".dmg"),
              let url = asset.browserDownloadURL,
              isTrustedGitHubURL(url, pathPrefix: trustedDownloadPathPrefix),
              url.pathExtension.lowercased() == "dmg"
        else { return nil }
        return url
    }

    private static func isTrustedGitHubURL(_ url: URL, pathPrefix: String) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == trustedGitHubHost
            && url.path.hasPrefix(pathPrefix)
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
    let session: URLSession

    static let maximumResponseBytes = 512 * 1024
    static let requestTimeoutSeconds: TimeInterval = 15

    init(session: URLSession = .shared) {
        self.session = session
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
