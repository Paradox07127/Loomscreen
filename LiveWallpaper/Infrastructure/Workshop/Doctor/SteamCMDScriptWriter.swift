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

    /// Real download for `itemID` under the bound Steam account. Same shape as
    /// the ownership probe (which is itself a `workshop_download_item`), so it
    /// inherits the validated `@NoPromptForPassword` cached-credential path.
    /// `itemID` is a `UInt64`, so the interpolation can only be digits.
    static func downloadItemScript(username: String, itemID: UInt64) throws -> String {
        guard validateUsername(username) else { throw SteamCMDScriptError.invalidUsername }
        return """
        @ShutdownOnFailedCommand 1
        @NoPromptForPassword 1
        login \(username)
        workshop_download_item 431960 \(itemID)
        quit
        """
    }

    /// Full Wallpaper Engine (app 431960) install/update. `ForcePlatformType
    /// windows` pulls the Windows depot on macOS (WPE has no Mac build); `validate`
    /// repairs the previous run's pruned tree so only the missing files re-download.
    static func appUpdateScript(username: String) throws -> String {
        guard validateUsername(username) else { throw SteamCMDScriptError.invalidUsername }
        return """
        @ShutdownOnFailedCommand 1
        @NoPromptForPassword 1
        @sSteamCmdForcePlatformType windows
        login \(username)
        app_update 431960 validate
        quit
        """
    }

    /// Logs the cached account out of SteamCMD, clearing its cached session.
    /// `login` first (cached, no password prompt) so `logout` targets the active
    /// account; the re-run cached-login probe is the source of truth for success.
    static func logoutScript(username: String) throws -> String {
        guard validateUsername(username) else { throw SteamCMDScriptError.invalidUsername }
        return """
        @NoPromptForPassword 1
        login \(username)
        logout
        quit
        """
    }

    /// Metadata-only query of app 431960. `app_info_update 1` forces a fresh
    /// pull so the printed public-branch `buildid` reflects the latest build —
    /// the cheap signal for "is an update available" without downloading.
    static func appInfoScript(username: String) throws -> String {
        guard validateUsername(username) else { throw SteamCMDScriptError.invalidUsername }
        return """
        @ShutdownOnFailedCommand 1
        @NoPromptForPassword 1
        login \(username)
        app_info_update 1
        app_info_print 431960
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
