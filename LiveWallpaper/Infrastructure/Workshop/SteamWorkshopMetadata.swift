#if !LITE_BUILD
import Foundation

/// Metadata for a Workshop item, derived from
/// `ISteamRemoteStorage/GetPublishedFileDetails/v1`. All fields are best
/// effort — Valve has been known to return partial responses for hidden /
/// banned / removed items, so optional fields fall back to placeholder text
/// in the UI rather than blocking the row.
struct SteamWorkshopMetadata: Equatable, Sendable {
    let publishedFileID: UInt64
    let title: String
    let shortDescription: String
    /// Optional — paste flow has no API key, so the supplemental
    /// `ISteamUser/GetPlayerSummaries/v2` lookup can't run.
    let creatorPersonaName: String?
    let previewImageURL: URL?
    let fileSizeBytes: UInt64?
    let timeUpdated: Date?
    let timeCreated: Date?
    let visibility: Visibility
    let isBanned: Bool
    let appID: UInt32
    let steamCommunityURL: URL

    /// Steam's documented visibility enum on `GetPublishedFileDetails`:
    /// `0` public, `1` friends-only, `2` private; anything else → `.unknown`.
    enum Visibility: String, Equatable, Sendable {
        case `public`
        case friendsOnly
        case `private`
        case unknown

        init(rawCode: Int?) {
            switch rawCode {
            case 0: self = .public
            case 1: self = .friendsOnly
            case 2: self = .private
            default: self = .unknown
            }
        }
    }
}

/// Failure modes surfaced by Workshop metadata requests.
enum SteamWorkshopMetadataError: Error, Equatable, Sendable {
    case invalidInput(WorkshopURLParser.InvalidReason)
    case networkUnreachable
    case timeout
    /// Steam denied metadata access; callers fall back to opening the item in Steam.
    case unauthorized
    case http(status: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case responseParseFailure
    case schemaMismatch
    case itemPrivate
    case itemBanned
    case itemNotFound
    case cancelled
    case unknown(String)
}

/// Calls `POST https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/`.
///
/// **No API key is required for this endpoint today** (community evidence;
/// not formally documented as keyless by Valve). We treat 401 / 403 as a
/// graceful-degradation signal — the row falls back to "Open in Steam".
///
/// The service is intentionally narrow: one method, no caching, no batching
/// of pubfileids across users (each row gets its own POST so a single
/// malformed id can't poison a batch). Callers layer coalescing, throttling,
/// and disk-cache of preview images on top.
@MainActor
final class SteamWorkshopMetadataService {

    /// Ephemeral by default — no cookies, no shared cache, no credential
    /// storage. ATS is enforced by the URLSession configuration.
    private let session: URLSession
    private let now: @Sendable () -> Date

    static let endpoint = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

    init(session: URLSession = SteamWorkshopMetadataService.defaultSession(),
         now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    /// Errors are pre-mapped onto `SteamWorkshopMetadataError` — no raw
    /// URLError / decoding errors leak to the UI.
    func fetch(publishedFileID id: UInt64) async -> Result<SteamWorkshopMetadata, SteamWorkshopMetadataError> {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        // Form-encoded request body matches every shipping third-party
        // Workshop tool. `itemcount=1` + `publishedfileids[0]=<id>`.
        let body = "itemcount=1&publishedfileids%5B0%5D=\(id)"
        request.httpBody = body.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                return .failure(.timeout)
            case .cancelled:
                return .failure(.cancelled)
            case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
                return .failure(.networkUnreachable)
            default:
                return .failure(.unknown(urlError.localizedDescription))
            }
        } catch {
            return .failure(.unknown(error.localizedDescription))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failure(.responseParseFailure)
        }

        switch http.statusCode {
        case 200:
            return Self.decode(data: data, publishedFileID: id)
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .failure(.rateLimited(retryAfter: retryAfter))
        case 401, 403:
            return .failure(.unauthorized)
        case 404:
            return .failure(.itemNotFound)
        default:
            return .failure(.http(status: http.statusCode))
        }
    }

    // MARK: - Decoding

    private static func decode(data: Data, publishedFileID requested: UInt64) -> Result<SteamWorkshopMetadata, SteamWorkshopMetadataError> {
        let envelope: GetPublishedFileDetailsEnvelope
        do {
            envelope = try JSONDecoder().decode(GetPublishedFileDetailsEnvelope.self, from: data)
        } catch {
            return .failure(.responseParseFailure)
        }
        guard let payload = envelope.response.publishedfiledetails.first else {
            return .failure(.itemNotFound)
        }
        // Steam encodes `publishedfileid` as a string in JSON.
        guard let id = UInt64(payload.publishedfileid), id == requested else {
            return .failure(.schemaMismatch)
        }
        // Steam result code: 1 = OK, 9 = not found, 15 = access denied.
        switch payload.result {
        case 1:
            break
        case 9:
            return .failure(.itemNotFound)
        case 15:
            return .failure(.itemPrivate)
        default:
            return .failure(.itemNotFound)
        }
        if let bannedInt = payload.banned, bannedInt != 0 {
            return .failure(.itemBanned)
        }
        let visibility = SteamWorkshopMetadata.Visibility(rawCode: payload.visibility)
        // Unknown visibility fails closed because only explicitly public items are safe to display.
        if visibility != .public {
            return .failure(.itemPrivate)
        }

        var preview: URL?
        if let candidate = payload.preview_url {
            switch WorkshopCDNHostAllowList.evaluate(candidate) {
            case .allowed(let url):
                preview = url
            case .rejected:
                preview = nil
            }
        }

        let communityURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
            ?? URL(string: "https://steamcommunity.com/")!

        return .success(SteamWorkshopMetadata(
            publishedFileID: id,
            title: payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            shortDescription: payload.short_description ?? payload.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            creatorPersonaName: nil,
            previewImageURL: preview,
            fileSizeBytes: payload.file_size.flatMap(UInt64.init),
            timeUpdated: payload.time_updated.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            timeCreated: payload.time_created.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            visibility: visibility,
            isBanned: (payload.banned ?? 0) != 0,
            appID: UInt32(payload.consumer_app_id ?? 0),
            steamCommunityURL: communityURL
        ))
    }

    // MARK: - URLSession factory

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Loomscreen/Workshop (+https://loomscreen.app/)"
        ]
        return URLSession(configuration: config)
    }
}

// MARK: - JSON Envelope

/// Top-level envelope returned by Valve. Fields are deliberately lenient —
/// unknown keys are ignored, every payload key is optional, and string ids
/// are kept as `String` (Steam serializes 64-bit ids as decimal strings).
private struct GetPublishedFileDetailsEnvelope: Decodable {
    let response: ResponseBody

    struct ResponseBody: Decodable {
        let result: Int?
        let resultcount: Int?
        let publishedfiledetails: [Payload]
    }

    // swiftlint:disable identifier_name (Valve JSON keys are snake_case).
    struct Payload: Decodable {
        let publishedfileid: String
        let result: Int
        let creator: String?
        let consumer_app_id: Int?
        let filename: String?
        let file_size: String?
        let preview_url: String?
        let url: String?
        let title: String?
        let description: String?
        let short_description: String?
        let time_created: Int?
        let time_updated: Int?
        let visibility: Int?
        /// Empirically Steam returns `0` / `1` as `Int`, **not** a JSON Bool.
        /// A `Bool?` decode would have killed every legitimate row. Kept as
        /// `Int?` so a future schema flip to `bool` doesn't regress us — we
        /// treat any non-zero value as banned.
        let banned: Int?
    }
    // swiftlint:enable identifier_name
}
#endif
