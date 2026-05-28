#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Darwin
import Foundation

/// Writes short-lived SteamCMD script files (mode 0600) into the user-bound
/// working directory. `+args` mode silently allows interactive prompts on
/// cache miss, so every download path uniformly drives SteamCMD through a
/// script that opens with `@ShutdownOnFailedCommand 1` + `@NoPromptForPassword 1`.
enum SteamCMDScriptWriter {

    static func writeScript(_ contents: String, in workdir: URL) throws -> URL {
        let scriptURL = workdir.appendingPathComponent("lw-\(UUID().uuidString).steamcmd", isDirectory: false)
        guard let data = contents.data(using: .utf8) else {
            throw SteamCMDScriptError.writeFailed("Script contents could not be encoded as UTF-8")
        }

        let path = scriptURL.path(percentEncoded: false)
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else {
            throw SteamCMDScriptError.writeFailed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(fd) }

        let writeError = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if written == 0 { return EIO }
                offset += written
            }
            return 0
        }
        guard writeError == 0 else {
            throw SteamCMDScriptError.writeFailed(String(cString: strerror(writeError)))
        }
        guard Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw SteamCMDScriptError.writeFailed(String(cString: strerror(errno)))
        }
        return scriptURL
    }

    static func deleteScript(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func cachedLoginProbeScript(username: String) throws -> String {
        guard validateUsername(username) else { throw SteamCMDScriptError.invalidUsername }
        return """
        @ShutdownOnFailedCommand 1
        @NoPromptForPassword 1
        login \(username)
        quit
        """
    }

    static func ownershipProbeScript(username: String, itemID: UInt64) throws -> String {
        guard validateUsername(username) else { throw SteamCMDScriptError.invalidUsername }
        return """
        @ShutdownOnFailedCommand 1
        @NoPromptForPassword 1
        login \(username)
        workshop_download_item 431960 \(itemID)
        quit
        """
    }

    /// `^[A-Za-z0-9_]{1,32}$` — Steam's documented login-name charset.
    static func validateUsername(_ username: String) -> Bool {
        guard !username.isEmpty, username.count <= 32 else { return false }
        return username.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_")
        }
    }
}

enum SteamCMDScriptError: Error, Equatable, Sendable {
    case invalidUsername
    case writeFailed(String)
}
#endif
