import Foundation

/// Generic JSON-on-disk store with atomic write + rotating `.bak` recovery.
///
/// Design goals
/// - Survives mid-write crashes: the previous file remains intact until the
///   new bytes are durably on disk and renamed into place (POSIX atomic).
/// - Survives a single corrupt `.json` file: `read()` falls back to `.bak`.
/// - Independent of `cfprefsd`: works on fresh user accounts where
///   `UserDefaults` may silently drop writes during launch.
/// - Sandbox-portable: lives under `Application Support/<bundle-id>/` which
///   macOS redirects into the sandbox container automatically if we ever
///   enable App Sandbox later.
/// - Multi-instance safe: an advisory `flock`-style POSIX lock prevents two
///   LiveWallpaper processes from clobbering each other's temp files.
/// - Privacy: files contain security-scoped bookmark Data and local path
///   metadata, so directory mode is forced to `0700` and file mode to
///   `0600` regardless of user umask.
///
/// The store is thread-confined to its actor (typically MainActor) by the
/// caller; the disk I/O itself is synchronous so callers can reason about
/// when a save has hit the filesystem.
struct AtomicFileStore<Value: Codable> {
    enum StoreError: Error, CustomStringConvertible {
        case writeFailed(underlying: Error)

        var description: String {
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
    static var maxReasonableFileSize: Int { 64 * 1024 * 1024 }

    let fileURL: URL
    let backupURL: URL
    let tempURL: URL
    let lockURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let category: Logger.Category

    init(
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

    /// True if a primary or backup payload exists on disk. Used by the
    /// migration path to decide whether to seed from `UserDefaults`.
    var hasPersistedValue: Bool {
        fileExists(fileURL) || fileExists(backupURL)
    }

    /// Reads the current payload, transparently falling back to the backup
    /// file when the primary is missing or corrupt. Returns `nil` only when
    /// both files are absent or undecodable.
    func read() -> Value? {
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
    /// Throws `StoreError.writeFailed` on any unrecoverable filesystem
    /// error — every path through this function wraps the underlying error
    /// so callers can treat it as a single failure type.
    func write(_ value: Value) throws {
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

    /// Writes raw bytes — used by migration paths that already have a JSON
    /// blob in `UserDefaults` and want to seed the file store without a
    /// decode/encode round-trip.
    func writeRaw(_ data: Data) throws {
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

    /// Removes the primary, backup, lock, and any stale tmp files. Used by
    /// the global "clean all settings" path.
    func delete() {
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
            // Cap read size: if the file is implausibly large (malicious /
            // truncated to nonsense), refuse to touch it on MainActor.
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

    /// Ensures the parent directory exists and that its permission bits are
    /// `0700` — security-scoped bookmark Data and absolute path metadata
    /// live here, so we don't want other local users reading them.
    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path(percentEncoded: false)) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } else {
            // Tighten perms on an existing directory if a previous install
            // (or a manual `mkdir`) created it with looser bits.
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path(percentEncoded: false)
            )
        }
    }

    /// 1. Acquire an exclusive POSIX lock so two app instances can't race.
    /// 2. Write payload to `.tmp` with mode `0600`.
    /// 3. `fsync` the temp file so the bytes are durably on disk before we
    ///    promote it — otherwise a power loss between rename and disk flush
    ///    can yield a zero-length file on next boot.
    /// 4. Atomically swap: existing `file.json` becomes `file.json.bak`,
    ///    `file.json.tmp` becomes `file.json`.
    /// 5. `fsync` the directory so the rename itself is durable.
    /// 6. Release the lock.
    private func writeAtomically(_ data: Data) throws {
        let lockFD = try acquireLock()
        defer { releaseLock(lockFD) }

        // Remove stale .tmp from a previously-aborted write.
        if fileExists(tempURL) {
            try fileManager.removeItem(at: tempURL)
        }

        try data.write(to: tempURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tempURL.path(percentEncoded: false)
        )

        // Force a flush of the temp file's data blocks before we hand it to
        // replaceItemAt — POSIX rename is atomic w.r.t. the directory entry
        // but the file's data is not guaranteed durable until fsync.
        if let handle = try? FileHandle(forWritingTo: tempURL) {
            try? handle.synchronize()
            try? handle.close()
        }

        // Rotate: current → backup, new → current. Done as two moves so the
        // semantics are explicit; replaceItemAt has historically been
        // flaky on case-insensitive volumes when target doesn't exist.
        if fileExists(fileURL) {
            if fileExists(backupURL) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: fileURL, to: backupURL)
        }
        try fileManager.moveItem(at: tempURL, to: fileURL)

        // fsync the directory entry so the rename is durable across power
        // loss. Best-effort — POSIX permits failing silently here.
        fsyncParentDirectory(of: fileURL)
    }

    /// Open (creating if necessary) the lock file and take an exclusive
    /// `flock`. Other LiveWallpaper instances block here until we release.
    private func acquireLock() throws -> Int32 {
        let path = lockURL.path(percentEncoded: false)
        // O_CREAT | O_RDWR with mode 0600 — file content is irrelevant, we
        // only care about the kernel's lock state attached to the fd.
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

    /// Calls `fsync(2)` on the parent directory's file descriptor so the
    /// rename's directory-entry update is durable. macOS uses `F_FULLFSYNC`
    /// for true platter-flush guarantees, but plain `fsync` on the
    /// directory is sufficient for crash consistency of the rename itself.
    private func fsyncParentDirectory(of url: URL) {
        let parent = url.deletingLastPathComponent().path(percentEncoded: false)
        let fd = open(parent, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }
}

/// Conditional Sendable: the store's collaborators (encoder, decoder,
/// fileManager) are effectively immutable in our use, so a value-typed copy
/// can safely cross actor boundaries — but only when the payload itself is
/// safe to share. Narrower than blanket `@unchecked Sendable` because we
/// don't want to grant Sendable to stores of non-Sendable payloads.
extension AtomicFileStore: @unchecked Sendable where Value: Sendable {}

// MARK: - Shared encoder configuration

extension JSONEncoder {
    /// `outputFormatting` is set to `.sortedKeys` so byte-equality holds
    /// across writes — this is what makes test fixtures stable and the
    /// migration path safe to re-run.
    static func configurationEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
