#if !LITE_BUILD
import Foundation
import Observation

/// On-disk library of user-imported Metal shaders. Lives in
/// `~/Library/Application Support/<bundle-id>/shaders/<uuid>.json`; one file
/// per shader avoids partial-write corruption hosing the entire library.
///
/// All disk reads / writes go through `Task.detached` so the MainActor never
/// blocks on FileManager; `shaders` updates on MainActor after each completes.
@MainActor
@Observable
public final class CustomShaderStore {
    public static let shared = CustomShaderStore()

    /// Sorted by `createdAt` ascending so existing grid positions stay stable
    /// across imports (newest lands at the end).
    public private(set) var shaders: [CustomShader] = []

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(using: fileManager)
        try? Self.ensureDirectoryExists(self.directory, using: fileManager)
        // Initial population is sync because the singleton is built once at
        // startup before any UI binds to `shaders`. Subsequent reloads go
        // through the async `reload()` to keep the MainActor free.
        self.shaders = Self.readShaders(at: self.directory, using: fileManager)
    }

    // MARK: - Public API

    public func reload() async {
        let directory = self.directory
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.readShaders(at: directory, using: .default)
        }.value
        shaders = loaded
    }

    public func shader(for id: UUID) -> CustomShader? {
        shaders.first { $0.id == id }
    }

    @discardableResult
    public func save(_ shader: CustomShader) async throws -> CustomShader {
        var entry = shader
        entry.modifiedAt = Date()
        let url = fileURL(for: entry.id)
        let payload = entry
        try await Task.detached(priority: .userInitiated) {
            try Self.writeShader(payload, to: url)
        }.value
        if let index = shaders.firstIndex(where: { $0.id == entry.id }) {
            shaders[index] = entry
        } else {
            shaders.append(entry)
            shaders.sort { $0.createdAt < $1.createdAt }
        }
        return entry
    }

    public func delete(_ id: UUID) async throws {
        let url = fileURL(for: id)
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }.value
        shaders.removeAll { $0.id == id }
    }

    // MARK: - Disk helpers (nonisolated, safe to call off-main)

    private nonisolated static func readShaders(at directory: URL, using fileManager: FileManager) -> [CustomShader] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [CustomShader] = []
        loaded.reserveCapacity(entries.count)
        for url in entries where url.pathExtension == "json" {
            // Filename must match the embedded UUID — drops orphans /
            // tampered records that could collide on cache keys.
            let filenameID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            guard let data = try? Data(contentsOf: url),
                  let shader = try? decoder.decode(CustomShader.self, from: data),
                  filenameID == shader.id else {
                continue
            }
            loaded.append(shader)
        }
        return loaded.sorted { $0.createdAt < $1.createdAt }
    }

    private nonisolated static func writeShader(_ shader: CustomShader, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(shader)
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
