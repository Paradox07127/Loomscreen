#if !LITE_BUILD && DIRECT_DISTRIBUTION
import CryptoKit
import Darwin
import Foundation

/// On-disk cache for `WorkshopQueryService` paged results. Atomic writes via
/// `<file>.tmp` + rename; atomic `clear()` via move-aside-then-delete. LRU
/// expiry on 5-minute TTL with a 100 MB hard cap.
actor WorkshopQueryCache {

    private static let ttl: TimeInterval = 300
    private static let hardCapBytes: Int64 = 100 * 1024 * 1024

    private let directoryURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()

        Task { [self] in await sweepExpiredAndEnforceCap() }
    }

    func read(forKey key: String) async -> WorkshopQueryPage? {
        do {
            try ensureDirectory()
            let url = fileURL(forKey: key)
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
            if isExpired(url) {
                try? fileManager.removeItem(at: url)
                return nil
            }
            let data = try Data(contentsOf: url)
            let payload = try decoder.decode(CachedPagePayload.self, from: data)
            // Bump mtime so the hard-cap eviction approximates LRU rather
            // than pure first-write order.
            try? fileManager.setAttributes(
                [.modificationDate: now()],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            return payload.page
        } catch {
            return nil
        }
    }

    func write(_ page: WorkshopQueryPage, forKey key: String) async {
        do {
            try ensureDirectory()
            let url = fileURL(forKey: key)
            let tmpURL = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".tmp", isDirectory: false)
            let payload = CachedPagePayload(page: page)
            let data = try encoder.encode(payload)
            try? fileManager.removeItem(at: tmpURL)
            try data.write(to: tmpURL)
            try Self.renameItem(at: tmpURL, to: url)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
            try enforceHardCap()
        } catch {
            return
        }
    }

    func sizeBytes() async -> Int64 {
        do {
            try ensureDirectory()
            return try cacheEntries().reduce(Int64(0)) { $0 + $1.sizeBytes }
        } catch {
            return 0
        }
    }

    func clear() async {
        do {
            if fileManager.fileExists(atPath: directoryURL.path(percentEncoded: false)) {
                let tombstone = directoryURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        "\(directoryURL.lastPathComponent).tobedeleted-\(UUID().uuidString)",
                        isDirectory: true
                    )
                try fileManager.moveItem(at: directoryURL, to: tombstone)
                try ensureDirectory()
                try? fileManager.removeItem(at: tombstone)
            } else {
                try ensureDirectory()
            }
        } catch {
            try? ensureDirectory()
        }
    }

    private func sweepExpiredAndEnforceCap() async {
        do {
            try ensureDirectory()
            try deleteExpiredEntries()
            try enforceHardCap()
        } catch {
            return
        }
    }

    private func ensureDirectory() throws {
        var isDirectory = ObjCBool(false)
        let path = directoryURL.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                try fileManager.removeItem(at: directoryURL)
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private func fileURL(forKey key: String) -> URL {
        directoryURL.appendingPathComponent(Self.safeFileName(forKey: key), isDirectory: false)
    }

    private func isExpired(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return modified < now().addingTimeInterval(-Self.ttl)
    }

    private func deleteExpiredEntries() throws {
        let cutoff = now().addingTimeInterval(-Self.ttl)
        for entry in try cacheEntries() where entry.modifiedAt < cutoff {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private func enforceHardCap() throws {
        var entries = try cacheEntries()
        var total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > Self.hardCapBytes else { return }
        entries.sort { $0.modifiedAt < $1.modifiedAt }
        for entry in entries {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.sizeBytes
            if total <= Self.hardCapBytes { break }
        }
    }

    private func cacheEntries() throws -> [CacheEntry] {
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else { return nil }
            return CacheEntry(url: url, modifiedAt: modifiedAt, sizeBytes: Int64(values.fileSize ?? 0))
        }
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("WorkshopQueryCache", isDirectory: true)
    }

    private static func safeFileName(forKey key: String) -> String {
        let lower = key.lowercased()
        if lower.range(of: #"^[a-f0-9]{64}$"#, options: [.regularExpression, .anchored]) != nil {
            return "\(lower).json"
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest).json"
    }

    private static func renameItem(at source: URL, to destination: URL) throws {
        try source.withUnsafeFileSystemRepresentation { sourcePath in
            try destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { throw CocoaError(.fileNoSuchFile) }
                if Darwin.rename(sourcePath, destinationPath) != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private struct CacheEntry {
        let url: URL
        let modifiedAt: Date
        let sizeBytes: Int64
    }
}

private struct CachedPagePayload: Codable {
    let items: [CachedItemPayload]
    let nextCursor: String?
    let totalAvailable: Int?

    init(page: WorkshopQueryPage) {
        self.items = page.items.map(CachedItemPayload.init(item:))
        self.nextCursor = page.nextCursor
        self.totalAvailable = page.totalAvailable
    }

    var page: WorkshopQueryPage? {
        let decoded = items.compactMap(\.item)
        guard decoded.count == items.count else { return nil }
        return WorkshopQueryPage(items: decoded, nextCursor: nextCursor, totalAvailable: totalAvailable)
    }
}

private struct CachedItemPayload: Codable {
    let id: UInt64
    let title: String
    let shortDescription: String
    let creatorID: String?
    let creatorPersonaName: String?
    let previewImageURL: String?
    let fileSizeBytes: UInt64?
    let timeUpdated: Date?
    let subscriptionCount: Int?
    let voteScore: Double?
    let tags: [String]
    let visibility: String
    let isBanned: Bool
    let steamCommunityURL: String

    init(item: WorkshopQueryItem) {
        self.id = item.id
        self.title = item.title
        self.shortDescription = item.shortDescription
        self.creatorID = item.creatorID
        self.creatorPersonaName = item.creatorPersonaName
        self.previewImageURL = item.previewImageURL?.absoluteString
        self.fileSizeBytes = item.fileSizeBytes
        self.timeUpdated = item.timeUpdated
        self.subscriptionCount = item.subscriptionCount
        self.voteScore = item.voteScore
        self.tags = item.tags
        self.visibility = item.visibility.rawValue
        self.isBanned = item.isBanned
        self.steamCommunityURL = item.steamCommunityURL.absoluteString
    }

    var item: WorkshopQueryItem? {
        guard let communityURL = URL(string: steamCommunityURL) else { return nil }
        let previewURL = previewImageURL.flatMap { URL(string: $0) }
        return WorkshopQueryItem(
            id: id,
            title: title,
            shortDescription: shortDescription,
            creatorID: creatorID,
            creatorPersonaName: creatorPersonaName,
            previewImageURL: previewURL,
            fileSizeBytes: fileSizeBytes,
            timeUpdated: timeUpdated,
            subscriptionCount: subscriptionCount,
            voteScore: voteScore,
            tags: tags,
            visibility: SteamWorkshopMetadata.Visibility(rawValue: visibility) ?? .unknown,
            isBanned: isBanned,
            steamCommunityURL: communityURL
        )
    }
}
#endif
