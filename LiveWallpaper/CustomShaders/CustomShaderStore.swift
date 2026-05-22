#if !LITE_BUILD
import Foundation
import Observation

/// On-disk library of user-imported Metal shaders. Lives in
/// `~/Library/Application Support/<bundle-id>/shaders/<uuid>.json`; one file
/// per shader avoids partial-write corruption hosing the entire library.
///
/// `@Observable` so SwiftUI's shader picker re-renders when the user
/// imports / deletes an entry. All disk I/O is dispatched off MainActor
/// inside each public method — callers stay on MainActor.
@MainActor
@Observable
public final class CustomShaderStore {
    public static let shared = CustomShaderStore()

    /// Sorted by `createdAt` ascending — newest entries land at the end of
    /// the grid so existing positions are stable across imports.
    public private(set) var shaders: [CustomShader] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(using: fileManager)
        try? Self.ensureDirectoryExists(self.directory, using: fileManager)
        reload()
    }

    // MARK: - Public API

    public func reload() {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            shaders = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [CustomShader] = []
        loaded.reserveCapacity(entries.count)
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let shader = try? decoder.decode(CustomShader.self, from: data) else {
                Logger.warning("CustomShaderStore: skipping unreadable shader at \(url.lastPathComponent)", category: .screenManager)
                continue
            }
            loaded.append(shader)
        }
        shaders = loaded.sorted { $0.createdAt < $1.createdAt }
    }

    public func shader(for id: UUID) -> CustomShader? {
        shaders.first { $0.id == id }
    }

    @discardableResult
    public func save(_ shader: CustomShader) throws -> CustomShader {
        var entry = shader
        entry.modifiedAt = Date()
        try writeToDisk(entry)
        if let index = shaders.firstIndex(where: { $0.id == entry.id }) {
            shaders[index] = entry
        } else {
            shaders.append(entry)
            shaders.sort { $0.createdAt < $1.createdAt }
        }
        return entry
    }

    public func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        shaders.removeAll { $0.id == id }
    }

    // MARK: - Internals

    private func writeToDisk(_ shader: CustomShader) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(shader)
        let url = fileURL(for: shader.id)
        try data.write(to: url, options: .atomic)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private static func defaultDirectory(using fileManager: FileManager) -> URL {
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "LiveWallpaper"
        let root = appSupport ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("shaders", isDirectory: true)
    }

    private static func ensureDirectoryExists(_ url: URL, using fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
#endif
