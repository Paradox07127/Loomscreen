import AppKit
import Foundation
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

    init() {
        self.isAuthorized = SettingsManager.shared.loadAerialsDirectoryBookmark() != nil
        self.assets = []
        self.lastScanError = nil
        self.isScanning = false
    }

    func requestAccess() async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = Self.suggestedDirectoryToGrant()
        panel.prompt = "Grant Access"
        panel.message = "macOS requires one-time approval to read Apple's wallpaper folder. Just click \"Grant Access\" — you do not need to pick any specific file."

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
        guard let directoryURL = resolveAuthorizedDirectory() else { return }

        // scanPlan / fileExists need this scope active.
        let didStartAccess = directoryURL.startAccessingSecurityScopedResource()
        guard didStartAccess else {
            let message = "Cannot access Apple Aerials directory. Grant access again."
            Logger.error(message, category: .fileAccess)
            lastScanError = message
            isAuthorized = false
            assets = []
            return
        }

        scanGeneration &+= 1
        let myGeneration = scanGeneration
        isScanning = true

        defer {
            directoryURL.stopAccessingSecurityScopedResource()
            if scanGeneration == myGeneration {
                isScanning = false
            }
        }

        guard let plan = Self.scanPlan(for: directoryURL) else {
            guard scanGeneration == myGeneration else { return }
            let message = "The selected folder doesn't contain Apple wallpapers. Try ~/Library/Application Support/com.apple.wallpaper/aerials/."
            Logger.warning(message, category: .fileAccess)
            SettingsManager.shared.clearAerialsDirectoryBookmark()
            isAuthorized = false
            lastScanError = message
            assets = []
            return
        }

        let metadataDir = directoryURL
        let result: Result<[AerialAsset], Error> = await Task.detached(priority: .userInitiated) {
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
        }.value

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
            guard !resolution.isStale else {
                let message = "Apple Aerials directory bookmark is stale. Grant access again."
                Logger.warning(message, category: .fileAccess)
                SettingsManager.shared.clearAerialsDirectoryBookmark()
                isAuthorized = false
                assets = []
                lastScanError = message
                return nil
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
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
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

        let assets = try videoURLs.map { url -> AerialAsset in
            let id = url.deletingPathExtension().lastPathComponent
            let entry = metadata[id]
            return AerialAsset(
                id: id,
                url: url,
                displayName: entry?.displayName ?? url.lastPathComponent,
                category: entry?.category,
                fileSize: fileSize(for: url),
                bookmarkData: try bookmarkCreator(url)
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

    /// Builds a bounded scan plan for recognized Apple wallpaper layouts.
    nonisolated static func scanPlan(for selectedDirectory: URL, fileManager: FileManager = .default) -> ScanPlan? {
        let last = selectedDirectory.lastPathComponent

        // Direct hits — leaf directories that contain .mov files.
        if last == "videos" {
            // Tahoe: com.apple.wallpaper/aerials/videos/
            return ScanPlan(root: selectedDirectory, recursive: false)
        }
        if last == "4KSDR240FPS" {
            return ScanPlan(root: selectedDirectory, recursive: false)
        }
        if last == ".wallpapers" {
            return ScanPlan(root: selectedDirectory, recursive: true)
        }
        if last == "aerials" {
            // Tahoe: com.apple.wallpaper/aerials → look for videos/ subdir.
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
            // Tahoe: parent of aerials/videos.
            let videos = selectedDirectory
                .appendingPathComponent("aerials", isDirectory: true)
                .appendingPathComponent("videos", isDirectory: true)
            if directoryExists(videos, fileManager: fileManager) {
                return ScanPlan(root: videos, recursive: false)
            }
            return nil
        }

        // Parent of a recognized layout.
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

        // idleassetsd top-level (Customer/4KSDR240FPS may live two levels down).
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
            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension.lowercased() == "mov" else {
                    return nil
                }
                return url
            }
        }

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
        // Tahoe layout: aerials/manifest/entries.json.
        let last = selectedDirectory.lastPathComponent

        if last == "videos" {
            // videos/ → ../manifest/entries.json
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

        // Legacy idleassetsd layout.
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
    /// Default Powerbox location; grants both aerial videos and metadata.
    nonisolated static func suggestedDirectoryToGrant(fileManager: FileManager = .default) -> URL {
        fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
            .appendingPathComponent("aerials", isDirectory: true)
    }
}
