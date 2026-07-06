import Foundation

/// Generic JSON-on-disk store with atomic write + rotating `.bak` recovery.
///
/// - Crash-safe: previous file stays intact until the new bytes are durably
///   renamed into place; `read()` falls back to `.bak` on corruption.
/// - Independent of `cfprefsd` / `UserDefaults`; sandbox-portable under
///   `Application Support/<bundle-id>/`.
/// - Multi-instance safe via POSIX advisory lock.
/// - Privacy: dir `0700`, file `0600` (bookmark Data + local paths).
///
/// Thread-confined to the caller's actor; disk I/O is synchronous.
public struct AtomicFileStore<Value: Codable> {
    public enum StoreError: Error, CustomStringConvertible {
        case writeFailed(underlying: Error)

        public var description: String {
            switch self {
            case .writeFailed(let error):
                return "AtomicFileStore: write failed — \(error.localizedDescription)"
            }
        }
    }

    /// Hard upper bound used by the read path. 64 MB is two orders of
    /// magnitude above any plausible LiveWallpaper config size, so we'd
    /// rather refuse to decode than block MainActor for seconds on a
    /// malicious or truncated file.
    public static var maxReasonableFileSize: Int { 64 * 1024 * 1024 }

    public let fileURL: URL
    public let backupURL: URL
    public let tempURL: URL
    public let lockURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let category: Logger.Category

    public init(
        fileURL: URL,
        encoder: JSONEncoder = .configurationEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        fileManager: FileManager = .default,
        category: Logger.Category = .settings
    ) {
        self.fileURL = fileURL
        self.backupURL = fileURL.appendingPathExtension("bak")
        self.tempURL = fileURL.appendingPathExtension("tmp")
        self.lockURL = fileURL.appendingPathExtension("lock")
        self.encoder = encoder
        self.decoder = decoder
        self.fileManager = fileManager
        self.category = category
    }

    /// Used by the migration path to decide whether to seed from `UserDefaults`.
    public var hasPersistedValue: Bool {
        fileExists(fileURL) || fileExists(backupURL)
    }

    /// Falls back to the backup file when the primary is missing or corrupt.
    public func read() -> Value? {
        if let value = decode(from: fileURL) {
            return value
        }

        if fileExists(fileURL) {
            Logger.warning(
                "AtomicFileStore primary unreadable at \(fileURL.lastPathComponent); attempting backup",
                category: category
            )
        }

        guard let backup = decode(from: backupURL) else {
            if fileExists(backupURL) {
                Logger.error(
                    "AtomicFileStore backup also unreadable at \(backupURL.lastPathComponent)",
                    category: category
                )
            }
            return nil
        }

        Logger.info(
            "AtomicFileStore recovered from backup at \(backupURL.lastPathComponent)",
            category: category
        )
        return backup
    }

    /// Writes `value` atomically, rotating the previous payload to `.bak`.
    public func write(_ value: Value) throws {
        do {
            try ensureDirectoryExists()
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }

        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }

        do {
            try writeAtomically(data)
        } catch {
            Logger.error(
                "AtomicFileStore write failed for \(fileURL.lastPathComponent): \(error.localizedDescription)",
                category: category
            )
            throw StoreError.writeFailed(underlying: error)
        }
    }

    /// Used by migration paths that already have a JSON blob in `UserDefaults` and want to seed the file store without a decode/encode round-trip.
    public func writeRaw(_ data: Data) throws {
        do {
            try ensureDirectoryExists()
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }

        do {
            try writeAtomically(data)
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }
    }

    /// Removes the primary, backup, lock, and any stale tmp files.
    public func delete() {
        for url in [fileURL, backupURL, tempURL, lockURL] where fileExists(url) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Logger.warning(
                    "AtomicFileStore could not remove \(url.lastPathComponent): \(error.localizedDescription)",
                    category: category
                )
            }
        }
    }

    // MARK: - Internals

    private func decode(from url: URL) -> Value? {
        guard fileExists(url) else { return nil }
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > Self.maxReasonableFileSize {
                Logger.error(
                    "AtomicFileStore refusing to decode oversized file \(url.lastPathComponent) (\(size) bytes)",
                    category: category
                )
                return nil
            }
            let data = try Data(contentsOf: url)
            return try decoder.decode(Value.self, from: data)
        } catch {
            Logger.warning(
                "AtomicFileStore decode failed for \(url.lastPathComponent): \(error.localizedDescription)",
                category: category
            )
            return nil
        }
    }

    /// Ensures the parent directory exists and that its permission bits are `0700` — security-scoped bookmark Data and absolute path metadata live here, so we don't want other local users reading them.
    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path(percentEncoded: false)
            )
        }
    }

    private func writeAtomically(_ data: Data) throws {
        let lockFD = try acquireLock()
        defer { releaseLock(lockFD) }

        if fileExists(tempURL) {
            try fileManager.removeItem(at: tempURL)
        }

        try data.write(to: tempURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tempURL.path(percentEncoded: false)
        )

        if let handle = try? FileHandle(forWritingTo: tempURL) {
            fullSync(handle.fileDescriptor, label: tempURL.lastPathComponent)
            try? handle.close()
        }

        var rotated = false
        do {
            if fileExists(fileURL) {
                if fileExists(backupURL) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.moveItem(at: fileURL, to: backupURL)
                rotated = true
            }
            try fileManager.moveItem(at: tempURL, to: fileURL)
        } catch {
            if rotated {
                // Rollback: restore backup back to primary location
                try? fileManager.moveItem(at: backupURL, to: fileURL)
            }
            throw error
        }

        fsyncParentDirectory(of: fileURL)
    }

    /// Open (creating if necessary) the lock file and take an exclusive `flock`.
    private func acquireLock() throws -> Int32 {
        let path = lockURL.path(percentEncoded: false)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw StoreError.writeFailed(underlying: POSIXError(
                .init(rawValue: errno) ?? .EIO
            ))
        }
        if flock(fd, LOCK_EX) != 0 {
            let err = errno
            close(fd)
            throw StoreError.writeFailed(underlying: POSIXError(
                .init(rawValue: err) ?? .EIO
            ))
        }
        return fd
    }

    private func releaseLock(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    /// Calls `fcntl(fd, F_FULLFSYNC)` on the parent directory's file descriptor so the rename's directory-entry update is durable.
    private func fsyncParentDirectory(of url: URL) {
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(parent, O_RDONLY)
        guard fd >= 0 else { return }
        fullSync(fd, label: url.deletingLastPathComponent().lastPathComponent)
        close(fd)
    }

    /// Best-effort strong durability. `F_FULLFSYNC` flushes the drive's write
    /// cache but isn't supported on every filesystem (returns -1/ENOTSUP), so
    /// on failure we downgrade to `fsync` rather than silently assuming the
    /// bytes reached stable storage. Never throws: atomicity is already
    /// guaranteed by the atomic write + rename, this only tightens the
    /// crash-durability window.
    private func fullSync(_ fd: Int32, label: String) {
        guard fcntl(fd, F_FULLFSYNC) == -1 else { return }
        let fullSyncErr = errno
        if fsync(fd) == 0 {
            Logger.warning(
                "AtomicFileStore F_FULLFSYNC unsupported for \(label) (errno \(fullSyncErr)); fell back to fsync",
                category: category
            )
        } else {
            Logger.error(
                "AtomicFileStore durability sync failed for \(label): F_FULLFSYNC errno \(fullSyncErr), fsync errno \(errno)",
                category: category
            )
        }
    }

    private func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }
}

/// Conditional Sendable: collaborators (encoder, decoder, fileManager) are
/// effectively immutable here, so a value-typed copy can cross actor boundaries
/// — but only when the payload is Sendable. Narrower than blanket `@unchecked
/// Sendable` so stores of non-Sendable payloads don't get Sendable for free.
extension AtomicFileStore: @unchecked Sendable where Value: Sendable {}

// MARK: - Shared encoder configuration

extension JSONEncoder {
    /// `outputFormatting` is set to `.sortedKeys` so byte-equality holds across writes — this is what makes test fixtures stable and the migration path safe to re-run.
    public static func configurationEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
