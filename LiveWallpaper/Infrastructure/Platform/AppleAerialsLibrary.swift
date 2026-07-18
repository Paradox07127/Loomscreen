import AppKit
import Foundation
import LiveWallpaperCore
import Observation

/// One Apple Aerial wallpaper asset discovered under idleassetsd.
struct AerialAsset: Identifiable, Hashable {
    let id: String
    let url: URL
    let displayName: String
    let category: String?
    let fileSize: Int64?
    let bookmarkData: Data
}

/// Scans Apple Aerial wallpapers after the user grants a directory bookmark.
@MainActor
@Observable
final class AppleAerialsLibrary {
    static let shared = AppleAerialsLibrary()

    private(set) var isAuthorized: Bool
    private(set) var assets: [AerialAsset]
    private(set) var lastScanError: String?
    private(set) var isScanning: Bool

    /// Drops stale async scan results.
    @ObservationIgnored private var scanGeneration: UInt64 = 0

    /// Cancels the in-flight scan when a newer `refresh()` supersedes it.
    @ObservationIgnored private var scanTask: Task<Result<[AerialAsset], Error>, Never>?

    init() {
        // Authorized if Apple's folder is directly readable (entitlement / standard
        // install) OR a prior Powerbox grant left a bookmark for a non-standard layout.
        self.isAuthorized = Self.defaultReadableDirectory() != nil
            || SettingsManager.shared.loadAerialsDirectoryBookmark() != nil
        self.assets = []
        self.lastScanError = nil
        self.isScanning = false
    }

    func requestAccess() async -> Bool {
        // Fast path: if the sandbox lets us list Apple's aerials store directly, no
        // Powerbox folder-grant is needed. No sandbox exception is claimed (kept MAS-
        // safe), so this only fires where the host actually permits the read; a strict
        // sandbox falls through to the picker below.
        if Self.defaultReadableDirectory() != nil {
            isAuthorized = true
            lastScanError = nil
            await refresh()
            return true
        }

        // Fallback: non-standard / older layout — grant via Powerbox + bookmark.
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.suggestedDirectoryToGrant()
        panel.prompt = L10n.Panel.grantAccess
        panel.message = L10n.Panel.appleAerialsAccessMessage

        guard panel.runModal() == .OK, let directoryURL = panel.url else {
            return false
        }

        do {
            let bookmarkData = try Self.createReadOnlyBookmark(for: directoryURL)
            SettingsManager.shared.saveAerialsDirectoryBookmark(bookmarkData)
            isAuthorized = true
            lastScanError = nil
            await refresh()
            return true
        } catch {
            let message = "Failed to save Apple Aerials access: \(error.localizedDescription)"
            Logger.error(message, category: .fileAccess)
            lastScanError = message
            isAuthorized = false
            return false
        }
    }

    func refresh() async {
        scanTask?.cancel()

        // Prefer the directly-readable Apple location (no security scope needed);
        // fall back to a user-granted bookmark for non-standard layouts.
        let directoryURL: URL
        let isSecurityScoped: Bool
        if let direct = Self.defaultReadableDirectory() {
            directoryURL = direct
            isSecurityScoped = false
            isAuthorized = true
        } else if let scoped = resolveAuthorizedDirectory() {
            directoryURL = scoped
            isSecurityScoped = true
        } else {
            return
        }

        // A bookmark URL needs its security scope opened; a directly-readable path
        // does not (and `startAccessingSecurityScopedResource` returns false on a
        // non-scoped URL, which must NOT be treated as an access failure).
        if isSecurityScoped {
            guard directoryURL.startAccessingSecurityScopedResource() else {
                let message = "Cannot access Apple Aerials directory. Grant access again."
                Logger.error(message, category: .fileAccess)
                lastScanError = message
                isAuthorized = false
                assets = []
                return
            }
        }

        scanGeneration &+= 1
        let myGeneration = scanGeneration
        isScanning = true

        defer {
            if isSecurityScoped {
                directoryURL.stopAccessingSecurityScopedResource()
            }
            if scanGeneration == myGeneration {
                isScanning = false
            }
        }

        guard let plan = Self.scanPlan(for: directoryURL) else {
            guard scanGeneration == myGeneration else { return }
            let message = "The selected folder doesn't contain Apple wallpapers. Try ~/Library/Application Support/com.apple.wallpaper/aerials/."
            Logger.warning(message, category: .fileAccess)
            lastScanError = message
            assets = []
            return
        }

        let metadataDir = directoryURL
        let task = Task.detached(priority: .userInitiated) { () -> Result<[AerialAsset], Error> in
            do {
                let metadata = Self.loadMetadata(for: metadataDir)
                let scanned = try Self.scanAssets(
                    in: plan.root,
                    metadata: metadata,
                    recursively: plan.recursive
                )
                return .success(scanned)
            } catch {
                return .failure(error)
            }
        }
        scanTask = task
        let result = await task.value

        guard scanGeneration == myGeneration else {
            Logger.debug("Discarding stale Aerials scan result", category: .fileAccess)
            return
        }

        switch result {
        case .success(let scanned):
            assets = scanned
            lastScanError = nil
            Logger.info("Scanned \(scanned.count) Apple Aerials assets", category: .fileAccess)
        case .failure(let error):
            let message = "Failed to scan Apple Aerials: \(error.localizedDescription)"
            Logger.error(message, category: .fileAccess)
            lastScanError = message
            assets = []
        }
    }

    func clearAccess() {
        scanGeneration &+= 1
        scanTask?.cancel()
        SettingsManager.shared.clearAerialsDirectoryBookmark()
        isAuthorized = false
        assets = []
        lastScanError = nil
        isScanning = false
    }
}

// MARK: - Bookmark Resolution

extension AppleAerialsLibrary {
    struct DirectoryBookmarkResolution {
        let url: URL
        let isStale: Bool
    }

    typealias DirectoryBookmarkResolver = (Data) throws -> DirectoryBookmarkResolution

    func resolveAuthorizedDirectory(
        using resolver: DirectoryBookmarkResolver = AppleAerialsLibrary.resolveDirectoryBookmark
    ) -> URL? {
        guard let bookmarkData = SettingsManager.shared.loadAerialsDirectoryBookmark() else {
            isAuthorized = false
            assets = []
            return nil
        }

        do {
            let resolution = try resolver(bookmarkData)
            if resolution.isStale {
                Logger.info(
                    "Apple Aerials directory bookmark is stale; refreshing in place",
                    category: .fileAccess
                )
                if let fresh = try? Self.createReadOnlyBookmark(for: resolution.url) {
                    SettingsManager.shared.saveAerialsDirectoryBookmark(fresh)
                }
            }
            isAuthorized = true
            return resolution.url
        } catch {
            let message = "Failed to resolve Apple Aerials directory bookmark: \(error.localizedDescription)"
            Logger.error(message, category: .fileAccess)
            isAuthorized = false
            assets = []
            lastScanError = message
            return nil
        }
    }

    nonisolated static func resolveDirectoryBookmark(_ bookmarkData: Data) throws -> DirectoryBookmarkResolution {
        let (url, isStale) = try SecurityScopedBookmarkResolver.shared.resolveData(bookmarkData)
        return DirectoryBookmarkResolution(url: url, isStale: isStale)
    }

    nonisolated static func createReadOnlyBookmark(for url: URL) throws -> Data {
        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        let noKeys: Set<URLResourceKey>? = nil
        let noRelativeURL: URL? = nil
        return try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: noKeys,
            relativeTo: noRelativeURL
        )
    }
}

// MARK: - Scanning

extension AppleAerialsLibrary {
    typealias BookmarkCreator = (URL) throws -> Data

    struct ScanPlan {
        let root: URL
        let recursive: Bool
    }

    nonisolated static func scanAssets(
        in directoryURL: URL,
        metadata: [String: AerialMetadata] = [:],
        recursively: Bool,
        fileManager: FileManager = .default,
        bookmarkCreator: BookmarkCreator = AppleAerialsLibrary.createReadOnlyBookmark
    ) throws -> [AerialAsset] {
        let videoURLs = try movFiles(
            in: directoryURL,
            recursively: recursively,
            fileManager: fileManager
        )

        let assets: [AerialAsset] = videoURLs.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            let entry = metadata[id]
            guard let bookmark = try? bookmarkCreator(url) else {
                Logger.warning(
                    "Skipping aerial '\(url.lastPathComponent)': bookmark creation failed",
                    category: .fileAccess
                )
                return nil
            }
            return AerialAsset(
                id: id,
                url: url,
                displayName: entry?.displayName ?? url.lastPathComponent,
                category: entry?.category,
                fileSize: fileSize(for: url),
                bookmarkData: bookmark
            )
        }

        return assets.sorted { lhs, rhs in
            let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameComparison == .orderedSame {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return nameComparison == .orderedAscending
        }
    }

    nonisolated static func scanPlan(for selectedDirectory: URL, fileManager: FileManager = .default) -> ScanPlan? {
        let last = selectedDirectory.lastPathComponent

        if last == "videos" {
            return ScanPlan(root: selectedDirectory, recursive: false)
        }
        if last == "4KSDR240FPS" {
            return ScanPlan(root: selectedDirectory, recursive: false)
        }
        if last == ".wallpapers" {
            return ScanPlan(root: selectedDirectory, recursive: true)
        }
        if last == "aerials" {
            let videos = selectedDirectory.appendingPathComponent("videos", isDirectory: true)
            if directoryExists(videos, fileManager: fileManager) {
                return ScanPlan(root: videos, recursive: false)
            }
            return nil
        }
        if last == "Customer" {
            return ScanPlan(root: selectedDirectory, recursive: true)
        }
        if last == "com.apple.wallpaper" {
            let videos = selectedDirectory
                .appendingPathComponent("aerials", isDirectory: true)
                .appendingPathComponent("videos", isDirectory: true)
            if directoryExists(videos, fileManager: fileManager) {
                return ScanPlan(root: videos, recursive: false)
            }
            return nil
        }

        let tahoeVideos = selectedDirectory
            .appendingPathComponent("aerials", isDirectory: true)
            .appendingPathComponent("videos", isDirectory: true)
        if directoryExists(tahoeVideos, fileManager: fileManager) {
            return ScanPlan(root: tahoeVideos, recursive: false)
        }

        let bundledWallpapers = selectedDirectory.appendingPathComponent(".wallpapers", isDirectory: true)
        if directoryExists(bundledWallpapers, fileManager: fileManager) {
            return ScanPlan(root: bundledWallpapers, recursive: true)
        }

        let customer = selectedDirectory.appendingPathComponent("Customer", isDirectory: true)
        if directoryExists(customer, fileManager: fileManager) {
            return ScanPlan(root: customer, recursive: true)
        }

        let codec4K = selectedDirectory.appendingPathComponent("4KSDR240FPS", isDirectory: true)
        if directoryExists(codec4K, fileManager: fileManager) {
            return ScanPlan(root: codec4K, recursive: false)
        }

        let idleassetsCustomer = selectedDirectory
            .appendingPathComponent("com.apple.idleassetsd", isDirectory: true)
            .appendingPathComponent("Customer", isDirectory: true)
        if directoryExists(idleassetsCustomer, fileManager: fileManager) {
            return ScanPlan(root: idleassetsCustomer, recursive: true)
        }

        return nil
    }

    nonisolated private static func movFiles(
        in directoryURL: URL,
        recursively: Bool,
        fileManager: FileManager
    ) throws -> [URL] {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        if recursively {
            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }
            var matches: [URL] = []
            var checked = 0
            for case let url as URL in enumerator {
                checked += 1
                if checked % 256 == 0, Task.isCancelled { return [] }
                if url.pathExtension.lowercased() == "mov" {
                    matches.append(url)
                }
            }
            return matches
        }

        if Task.isCancelled { return [] }
        return try fileManager
            .contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "mov" }
    }

    nonisolated private static func fileSize(for url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    nonisolated private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

// MARK: - Metadata

extension AppleAerialsLibrary {
    struct AerialMetadata: Equatable {
        let displayName: String?
        let category: String?
    }

    nonisolated static func loadMetadata(for selectedDirectory: URL, fileManager: FileManager = .default) -> [String: AerialMetadata] {
        guard let entriesURL = entriesURL(for: selectedDirectory, fileManager: fileManager),
              let data = try? Data(contentsOf: entriesURL) else {
            return [:]
        }
        return metadataByAssetID(from: data)
    }

    nonisolated static func metadataByAssetID(from data: Data) -> [String: AerialMetadata] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }

        if let dictionary = json as? [String: Any] {
            if let entries = dictionary["entries"] as? [[String: Any]] {
                return metadataByAssetID(fromEntries: entries)
            }
            if let assets = dictionary["assets"] as? [[String: Any]] {
                return metadataByAssetID(fromEntries: assets)
            }
            let pairs = dictionary.compactMap { key, value -> (String, AerialMetadata)? in
                guard let dict = value as? [String: Any] else { return nil }
                return (key, metadata(from: dict))
            }
            return Dictionary(uniqueKeysWithValues: pairs)
        }

        if let entries = json as? [[String: Any]] {
            return metadataByAssetID(fromEntries: entries)
        }
        return [:]
    }

    nonisolated private static func metadataByAssetID(fromEntries entries: [[String: Any]]) -> [String: AerialMetadata] {
        let pairs = entries.compactMap { entry -> (String, AerialMetadata)? in
            guard let id = stringValue(forAnyKey: ["id", "uuid", "assetId", "identifier"], in: entry) else {
                return nil
            }
            return (id, metadata(from: entry))
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    nonisolated private static func metadata(from dictionary: [String: Any]) -> AerialMetadata {
        AerialMetadata(
            displayName: stringValue(forAnyKey: ["accessibilityLabel", "displayName", "name", "title", "localizedNameKey"], in: dictionary),
            category: stringValue(forAnyKey: ["shotID", "category", "categoryId", "subcategoryId"], in: dictionary)
        )
    }

    nonisolated private static func stringValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated private static func entriesURL(for selectedDirectory: URL, fileManager: FileManager) -> URL? {
        let last = selectedDirectory.lastPathComponent

        if last == "videos" {
            let manifestEntries = selectedDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("manifest", isDirectory: true)
                .appendingPathComponent("entries.json", isDirectory: false)
            if fileManager.fileExists(atPath: manifestEntries.path(percentEncoded: false)) {
                return manifestEntries
            }
        }

        let aerialsManifest = selectedDirectory
            .appendingPathComponent("aerials", isDirectory: true)
            .appendingPathComponent("manifest", isDirectory: true)
            .appendingPathComponent("entries.json", isDirectory: false)
        if fileManager.fileExists(atPath: aerialsManifest.path(percentEncoded: false)) {
            return aerialsManifest
        }

        let directManifest = selectedDirectory
            .appendingPathComponent("manifest", isDirectory: true)
            .appendingPathComponent("entries.json", isDirectory: false)
        if fileManager.fileExists(atPath: directManifest.path(percentEncoded: false)) {
            return directManifest
        }

        if last == "Customer" {
            return selectedDirectory.appendingPathComponent("entries.json", isDirectory: false)
        }
        let parent = selectedDirectory.deletingLastPathComponent()
        if parent.lastPathComponent == "Customer" {
            return parent.appendingPathComponent("entries.json", isDirectory: false)
        }
        let customerDirectory = selectedDirectory.appendingPathComponent("Customer", isDirectory: true)
        if directoryExists(customerDirectory, fileManager: fileManager) {
            return customerDirectory.appendingPathComponent("entries.json", isDirectory: false)
        }
        return selectedDirectory.appendingPathComponent("entries.json", isDirectory: false)
    }
}

// MARK: - Default Locations

extension AppleAerialsLibrary {
    /// The user's REAL home. In the App Sandbox `FileManager.homeDirectoryForCurrentUser`
    /// and `NSHomeDirectory()` both return the container (`~/Library/Containers/<id>/Data`),
    /// so a path built from them points at a folder that does NOT exist — which is why
    /// the grant panel used to ignore its `directoryURL` and reopen at the last-used
    /// location. The POSIX user DB reports the true `/Users/<name>`, which is also what
    /// the home-relative read-only entitlement is resolved against. (Verified: getpwuid
    /// returns /Users/<name> in-sandbox while NSHomeDirectory returns the container.)
    nonisolated static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// macOS 26/27 (Tahoe) per-user aerials store; also the grant panel's directory hint.
    nonisolated static func suggestedDirectoryToGrant(fileManager: FileManager = .default) -> URL {
        realHomeDirectory()
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    /// The known Apple aerials locations readable WITHOUT a Powerbox grant (covered
    /// by the read-only entitlement exceptions). Returns the first that exists,
    /// newest layout first. `nil` when neither is present (non-standard install) —
    /// the caller then falls back to the folder-grant panel, which stays as the
    /// version-proof path for any layout these two don't cover.
    nonisolated static func defaultReadableDirectory(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            // macOS 26/27 (Tahoe): per-user store (videos + manifest + thumbnails).
            realHomeDirectory()
                .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true),
            // macOS 14/15 (Sonoma/Sequoia): system-wide idle assets.
            URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd", isDirectory: true),
        ]
        // Probe real readability, not just existence: with no sandbox exception a
        // strict host can allow stat() while denying the directory read, and an
        // existence-only check would authorize a store we can't actually scan (and
        // then never fall through to the Powerbox grant). A successful shallow list
        // is the real gate — the opportunistic fast path, valid with or without an
        // entitlement.
        return candidates.first { directoryIsReadable($0, fileManager: fileManager) }
    }

    nonisolated private static func directoryIsReadable(_ url: URL, fileManager: FileManager) -> Bool {
        guard directoryExists(url, fileManager: fileManager) else { return false }
        return (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) != nil
    }
}
