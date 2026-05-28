#if !LITE_BUILD && DIRECT_DISTRIBUTION
import CryptoKit
import Foundation
import os

enum WorkshopSortMode: String, Sendable, Equatable, CaseIterable {
    case topRated
    case newest
    case trending
    case mostSubscribed
    case search

    var queryTypeCode: Int {
        switch self {
        case .topRated: return 0
        case .newest: return 1
        case .trending: return 3
        case .mostSubscribed: return 9
        case .search: return 12
        }
    }

    var displayName: String {
        switch self {
        case .topRated: return "Top Rated"
        case .newest: return "Newest"
        case .trending: return "Trending"
        case .mostSubscribed: return "Most Subscribed"
        case .search: return "Search"
        }
    }

    var requiresDays: Bool { self == .trending }
}

struct WorkshopQueryRequest: Equatable, Hashable, Sendable {
    let sort: WorkshopSortMode
    let searchText: String
    let cursor: String
    let numPerPage: Int
    let language: String?
    let days: Int?
    let requiredTags: [String]
    let excludedTags: [String]
    let returnPreviews: Bool
    let returnTags: Bool
    let returnMetadata: Bool
    let returnShortDescription: Bool

    init(
        sort: WorkshopSortMode,
        searchText: String = "",
        cursor: String = "*",
        numPerPage: Int = 50,
        language: String? = nil,
        days: Int? = nil,
        requiredTags: [String] = [],
        excludedTags: [String] = [],
        returnPreviews: Bool = true,
        returnTags: Bool = true,
        returnMetadata: Bool = true,
        returnShortDescription: Bool = true
    ) {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSort: WorkshopSortMode = normalizedSearch.isEmpty ? sort : .search

        self.sort = effectiveSort
        self.searchText = normalizedSearch
        self.cursor = cursor.isEmpty ? "*" : cursor
        self.numPerPage = min(max(numPerPage, 1), 100)
        self.language = Self.canonicalLanguage(language)
        self.days = effectiveSort.requiresDays ? 7 : days.flatMap { $0 > 0 ? $0 : nil }
        self.requiredTags = Self.canonicalTags(requiredTags)
        self.excludedTags = Self.canonicalTags(excludedTags)
        self.returnPreviews = returnPreviews
        self.returnTags = returnTags
        self.returnMetadata = returnMetadata
        self.returnShortDescription = returnShortDescription
    }

    private static func canonicalLanguage(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func canonicalTags(_ tags: [String]) -> [String] {
        tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "en_US_POSIX")) }
            .filter { !$0.isEmpty }
            .sorted()
    }
}

struct WorkshopQueryItem: Identifiable, Sendable, Equatable {
    let id: UInt64
    let title: String
    let shortDescription: String
    let creatorPersonaName: String?
    /// Already filtered through `WorkshopCDNHostAllowList`. Load via
    /// `WorkshopPreviewImageLoader` (the existing v1 loader).
    let previewImageURL: URL?
    let fileSizeBytes: UInt64?
    let timeUpdated: Date?
    let subscriptionCount: Int?
    let voteScore: Double?
    let tags: [String]
    let visibility: SteamWorkshopMetadata.Visibility
    let isBanned: Bool
    let steamCommunityURL: URL
}

struct WorkshopQueryPage: Sendable, Equatable {
    let items: [WorkshopQueryItem]
    let nextCursor: String?
    let totalAvailable: Int?
}

enum WorkshopQueryError: Error, Equatable, Sendable {
    case missingAPIKey
    case unauthorized
    case keyDisabled
    case rateLimited(retryAfter: TimeInterval?)
    case networkUnreachable
    case timeout
    case http(status: Int)
    case responseParseFailure
    case schemaMismatch
    case cancelled
}

enum WorkshopQueryCacheKey {
    static func canonical(_ request: WorkshopQueryRequest) -> String {
        sha256Hex(of: canonicalRequestData(request))
    }

    private static func canonicalRequestData(_ request: WorkshopQueryRequest) -> Data {
        let canonical = CanonicalRequest(
            appid: WorkshopQueryService.wallpaperEngineAppID,
            queryType: request.sort.queryTypeCode,
            searchText: request.searchText,
            cursor: request.cursor,
            numPerPage: request.numPerPage,
            language: request.language,
            days: request.days,
            requiredTags: request.requiredTags,
            excludedTags: request.excludedTags,
            returnPreviews: request.returnPreviews,
            returnTags: request.returnTags,
            returnMetadata: request.returnMetadata,
            returnShortDescription: request.returnShortDescription
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(canonical)) ?? Data()
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct CanonicalRequest: Encodable {
        let appid: Int
        let queryType: Int
        let searchText: String
        let cursor: String
        let numPerPage: Int
        let language: String?
        let days: Int?
        let requiredTags: [String]
        let excludedTags: [String]
        let returnPreviews: Bool
        let returnTags: Bool
        let returnMetadata: Bool
        let returnShortDescription: Bool

        private enum CodingKeys: String, CodingKey {
            case appid
            case queryType = "query_type"
            case searchText = "search_text"
            case cursor
            case numPerPage = "numperpage"
            case language
            case days
            case requiredTags = "requiredtags"
            case excludedTags = "excludedtags"
            case returnPreviews = "return_previews"
            case returnTags = "return_tags"
            case returnMetadata = "return_metadata"
            case returnShortDescription = "return_short_description"
        }
    }
}

actor WorkshopQueryService {

    static let wallpaperEngineAppID = 431960

    private static let queryFilesEndpoint = URL(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
    private static let supportedAPIListEndpoint = URL(string: "https://api.steampowered.com/ISteamWebAPIUtil/GetSupportedAPIList/v1/")!
    private static let maxAttempts = 3
    private static let tokenCapacity = 5.0
    private static let tokenRefillPerSecond = 1.0
    private static let apiKeyPattern = #"^[A-Fa-f0-9]{32}$"#

    private let keychain: WorkshopKeychainStore
    private let session: URLSession
    private let cache: WorkshopQueryCache
    private let logger = os.Logger(subsystem: "com.loomscreen.livewallpaper", category: "WorkshopQuery")

    private var inflight: [WorkshopQueryRequest: Task<WorkshopQueryPage, Error>] = [:]
    private var tokenBucket = tokenCapacity
    private var tokenRefilledAt = Date()

    init(
        keychain: WorkshopKeychainStore,
        cache: WorkshopQueryCache = WorkshopQueryCache(),
        session: URLSession = .workshopQuerySession(timeout: 20)
    ) {
        self.keychain = keychain
        self.session = session
        self.cache = cache
    }

    /// Exposes the disk cache so Settings can read/clear it.
    nonisolated var diskCache: WorkshopQueryCache { cache }

    func fetch(_ request: WorkshopQueryRequest) async throws -> WorkshopQueryPage {
        if let task = inflight[request] {
            return try await task.value
        }
        let cacheKey = WorkshopQueryCacheKey.canonical(request)
        let task = Task { [self] in
            try await fetchFromCacheOrNetwork(request, cacheKey: cacheKey)
        }
        inflight[request] = task
        do {
            let page = try await task.value
            inflight[request] = nil
            return page
        } catch {
            inflight[request] = nil
            throw error
        }
    }

    func validateAPIKey(_ key: String) async throws -> Bool {
        guard Self.isValidAPIKeyShape(key) else {
            throw WorkshopQueryError.unauthorized
        }
        var components = URLComponents(url: Self.supportedAPIListEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else {
            throw WorkshopQueryError.schemaMismatch
        }
        try await acquireToken()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WorkshopQueryError.responseParseFailure
        }

        switch http.statusCode {
        case 200:
            if Self.bodyContainsDisabledKeyHint(data) { throw WorkshopQueryError.keyDisabled }
            return true
        case 401:
            throw WorkshopQueryError.unauthorized
        case 403:
            throw Self.bodyContainsDisabledKeyHint(data) ? WorkshopQueryError.keyDisabled : WorkshopQueryError.unauthorized
        case 429:
            throw WorkshopQueryError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default:
            throw WorkshopQueryError.http(status: http.statusCode)
        }
    }

    private func fetchFromCacheOrNetwork(_ request: WorkshopQueryRequest, cacheKey: String) async throws -> WorkshopQueryPage {
        if let cached = await cache.read(forKey: cacheKey) {
            return cached
        }
        let apiKey: String
        do {
            guard let storedKey = try await keychain.loadWebAPIKey() else {
                throw WorkshopQueryError.missingAPIKey
            }
            apiKey = storedKey
        } catch let error as WorkshopQueryError {
            throw error
        } catch {
            throw WorkshopQueryError.missingAPIKey
        }
        let page = try await performQuery(request, apiKey: apiKey)
        await cache.write(page, forKey: cacheKey)
        return page
    }

    private func performQuery(_ request: WorkshopQueryRequest, apiKey: String) async throws -> WorkshopQueryPage {
        let url = try buildQueryURL(for: request, apiKey: apiKey)

        for attempt in 0..<Self.maxAttempts {
            try Task.checkCancellation()
            try await acquireToken()

            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.timeoutInterval = 20

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch {
                throw Self.mapNetworkError(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw WorkshopQueryError.responseParseFailure
            }

            switch http.statusCode {
            case 200:
                return try decodeQueryPage(data)
            case 401:
                throw WorkshopQueryError.unauthorized
            case 403:
                throw Self.bodyContainsDisabledKeyHint(data) ? WorkshopQueryError.keyDisabled : WorkshopQueryError.unauthorized
            case 429:
                let retryAfter = Self.retryAfter(from: http)
                guard attempt < Self.maxAttempts - 1 else {
                    throw WorkshopQueryError.rateLimited(retryAfter: retryAfter)
                }
                try await sleepBeforeRetry(attempt: attempt, retryAfter: retryAfter)
            case 500...599:
                guard attempt < Self.maxAttempts - 1 else {
                    throw WorkshopQueryError.http(status: http.statusCode)
                }
                try await sleepBeforeRetry(attempt: attempt, retryAfter: nil)
            default:
                throw WorkshopQueryError.http(status: http.statusCode)
            }
        }
        throw WorkshopQueryError.responseParseFailure
    }

    private func buildQueryURL(for request: WorkshopQueryRequest, apiKey: String) throws -> URL {
        var components = URLComponents(url: Self.queryFilesEndpoint, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "appid", value: String(Self.wallpaperEngineAppID)),
            URLQueryItem(name: "numperpage", value: String(request.numPerPage)),
            URLQueryItem(name: "query_type", value: String(request.sort.queryTypeCode)),
            URLQueryItem(name: "cursor", value: request.cursor),
            URLQueryItem(name: "return_previews", value: Self.steamBool(request.returnPreviews)),
            URLQueryItem(name: "return_tags", value: Self.steamBool(request.returnTags)),
            URLQueryItem(name: "return_metadata", value: Self.steamBool(request.returnMetadata)),
            URLQueryItem(name: "return_short_description", value: Self.steamBool(request.returnShortDescription))
        ]
        if !request.searchText.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: request.searchText))
        }
        if let language = request.language {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        if let days = request.days {
            queryItems.append(URLQueryItem(name: "days", value: String(days)))
        }
        for (index, tag) in request.requiredTags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in request.excludedTags.enumerated() {
            queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw WorkshopQueryError.schemaMismatch }
        return url
    }

    private func acquireToken() async throws {
        while true {
            refillTokenBucket()
            if tokenBucket >= 1 {
                tokenBucket -= 1
                return
            }
            let seconds = (1 - tokenBucket) / Self.tokenRefillPerSecond
            try await Self.sleep(seconds: seconds)
        }
    }

    private func refillTokenBucket() {
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(tokenRefilledAt))
        guard elapsed > 0 else { return }
        tokenBucket = min(Self.tokenCapacity, tokenBucket + elapsed * Self.tokenRefillPerSecond)
        tokenRefilledAt = now
    }

    private func sleepBeforeRetry(attempt: Int, retryAfter: TimeInterval?) async throws {
        let exponential = min(60, pow(2, Double(attempt)) + Double.random(in: 0...1))
        let delay = retryAfter.map { min(60, max($0, exponential)) } ?? exponential
        logger.debug("Workshop query retry scheduled after \(delay, privacy: .public) s")
        try await Self.sleep(seconds: delay)
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let clamped = max(0, min(60, seconds))
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }

    private func decodeQueryPage(_ data: Data) throws -> WorkshopQueryPage {
        let envelope: QueryFilesEnvelope
        do {
            envelope = try JSONDecoder().decode(QueryFilesEnvelope.self, from: data)
        } catch {
            throw WorkshopQueryError.responseParseFailure
        }
        if Self.messageIndicatesDisabled(envelope.response.resultmsg) {
            throw WorkshopQueryError.keyDisabled
        }
        guard let details = envelope.response.publishedfiledetails else {
            throw WorkshopQueryError.schemaMismatch
        }
        let items = details.compactMap { Self.item(from: $0, logger: logger) }
        let nextCursor = envelope.response.next_cursor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyWorkshopQuery
        return WorkshopQueryPage(items: items, nextCursor: nextCursor, totalAvailable: envelope.response.total?.value)
    }

    private static func item(from payload: QueryFilesPayload, logger: os.Logger) -> WorkshopQueryItem? {
        guard let idString = payload.publishedfileid?.value, let id = UInt64(idString) else { return nil }

        var previewURL: URL?
        if let candidate = payload.preview_url?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
            switch WorkshopCDNHostAllowList.evaluate(candidate) {
            case .allowed(let url):
                previewURL = url
            case .rejected(let reason):
                let redacted = WorkshopDiagnosticRedactor.redact(candidate)
                logger.warning("Rejected Workshop query preview URL (\(reason.rawValue, privacy: .public)): \(redacted, privacy: .public)")
            }
        }

        let title = WorkshopDiagnosticRedactor.redact(
            payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery
                ?? "Untitled Workshop Item"
        )
        let shortDescription = WorkshopDiagnosticRedactor.redact(
            payload.short_description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery
                ?? payload.description?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery
                ?? ""
        )
        let tags = (payload.tags ?? [])
            .compactMap { $0.displayName }
            .map(WorkshopDiagnosticRedactor.redact)
            .filter { !$0.isEmpty }

        let communityURL = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
            ?? URL(string: "https://steamcommunity.com/")!

        return WorkshopQueryItem(
            id: id,
            title: title,
            shortDescription: shortDescription,
            creatorPersonaName: nil,
            previewImageURL: previewURL,
            fileSizeBytes: payload.file_size?.value,
            timeUpdated: payload.time_updated?.dateValue,
            subscriptionCount: payload.subscriptions?.value ?? payload.lifetime_subscriptions?.value,
            voteScore: Self.clampedScore(payload.vote_data?.score?.value ?? payload.score?.value),
            tags: tags,
            visibility: SteamWorkshopMetadata.Visibility(rawCode: payload.visibility?.value),
            isBanned: payload.banned?.value ?? false,
            steamCommunityURL: communityURL
        )
    }

    private static func clampedScore(_ score: Double?) -> Double? {
        guard let score, score.isFinite else { return nil }
        return min(1, max(0, score))
    }

    private static func bodyContainsDisabledKeyHint(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(ValveErrorEnvelope.self, from: data) else { return false }
        return messageIndicatesDisabled(envelope.response?.resultmsg)
    }

    private static func messageIndicatesDisabled(_ message: String?) -> Bool {
        guard let message else { return false }
        return message.range(of: "disabled", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    private static func steamBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func isValidAPIKeyShape(_ key: String) -> Bool {
        key.range(of: apiKeyPattern, options: [.regularExpression, .anchored]) != nil
    }

    private static func mapNetworkError(_ error: Error) -> WorkshopQueryError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .networkUnreachable }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost, .cannotConnectToHost:
            return .networkUnreachable
        default: return .networkUnreachable
        }
    }
}

extension URLSession {
    static func workshopQuerySession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 30)
        config.httpAdditionalHeaders = [
            "User-Agent": "Loomscreen/Workshop (LiveWallpaper Pro)"
        ]
        return URLSession(configuration: config)
    }
}

// MARK: - Steam response wire format

private struct QueryFilesEnvelope: Decodable {
    let response: ResponseBody

    struct ResponseBody: Decodable {
        let total: LossyIntWQ?
        let next_cursor: String?
        let result: LossyIntWQ?
        let resultmsg: String?
        let publishedfiledetails: [QueryFilesPayload]?
    }
}

private struct QueryFilesPayload: Decodable {
    let publishedfileid: LossyStringWQ?
    let title: String?
    let description: String?
    let short_description: String?
    let preview_url: String?
    let file_size: LossyUInt64WQ?
    let time_updated: LossyDoubleWQ?
    let visibility: LossyIntWQ?
    let banned: LossyBoolWQ?
    let subscriptions: LossyIntWQ?
    let lifetime_subscriptions: LossyIntWQ?
    let score: LossyDoubleWQ?
    let vote_data: VoteData?
    let tags: [WorkshopTagPayload]?

    struct VoteData: Decodable {
        let score: LossyDoubleWQ?
    }
}

private struct WorkshopTagPayload: Decodable {
    let tag: String?
    let display_name: String?

    var displayName: String? {
        (display_name ?? tag)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyWorkshopQuery
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            self.tag = try keyed.decodeIfPresent(String.self, forKey: .tag)
            self.display_name = try keyed.decodeIfPresent(String.self, forKey: .display_name)
            return
        }
        let single = try decoder.singleValueContainer()
        self.tag = try? single.decode(String.self)
        self.display_name = nil
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case display_name
    }
}

private struct ValveErrorEnvelope: Decodable {
    let response: ResponseBody?

    struct ResponseBody: Decodable {
        let result: LossyIntWQ?
        let resultmsg: String?
    }
}

// Suffix `WQ` to avoid colliding with similarly-named lossy decoders elsewhere
// in the codebase if they get added later.

private struct LossyStringWQ: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let uint64 = try? container.decode(UInt64.self) {
            value = String(uint64)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string-like value")
        }
    }
}

private struct LossyIntWQ: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected int-like value")
        }
    }
}

private struct LossyUInt64WQ: Decodable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let uint64 = try? container.decode(UInt64.self) {
            value = uint64
        } else if let int = try? container.decode(Int.self), int >= 0 {
            value = UInt64(int)
        } else if let string = try? container.decode(String.self), let uint64 = UInt64(string) {
            value = uint64
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected uint64-like value")
        }
    }
}

private struct LossyDoubleWQ: Decodable {
    let value: Double

    var dateValue: Date? {
        guard value > 0, value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self), let double = Double(string) {
            value = double
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected double-like value")
        }
    }
}

private struct LossyBoolWQ: Decodable {
    let value: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else if let string = try? container.decode(String.self) {
            value = string == "1" || string.caseInsensitiveCompare("true") == .orderedSame
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected bool-like value")
        }
    }
}

private extension String {
    var nilIfEmptyWorkshopQuery: String? { isEmpty ? nil : self }
}
#endif
