#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Workshop download script + output parsing")
struct WorkshopDownloadTests {

    @Test("Download script logs in and downloads the item under the WE app id")
    func downloadScriptShape() throws {
        let script = try SteamCMDScriptWriter.downloadItemScript(username: "alice_01", itemID: 1234567890)
        #expect(script.contains("@NoPromptForPassword 1"))
        #expect(script.contains("login alice_01"))
        #expect(script.contains("workshop_download_item 431960 1234567890"))
        #expect(script.contains("quit"))
    }

    @Test("Download script rejects an out-of-charset username")
    func downloadScriptRejectsBadUsername() {
        #expect(throws: SteamCMDScriptError.invalidUsername) {
            _ = try SteamCMDScriptWriter.downloadItemScript(username: "alice; rm -rf /", itemID: 1)
        }
    }

    @Test("Captures the quoted destination from a SteamCMD success line")
    func capturesDownloadPath() {
        let stdout = """
        Redirecting stderr to '/tmp/steamcmd/logs/stderr.txt'
        Logging in user 'alice_01' [U:1:123] to Steam Public...OK
        Success. Downloaded item 1234567890 to "/Users/x/steamcmd/steamapps/workshop/content/431960/1234567890" (1048576 bytes after 1 chunks)
        """
        #expect(
            SteamCMDDoctorService.capturedDownloadPath(stdout: stdout, itemID: 1234567890)
                == "/Users/x/steamcmd/steamapps/workshop/content/431960/1234567890"
        )
    }

    @Test("Does not match a different item id or a failure line")
    func ignoresNonMatchingOutput() {
        let success = #"Success. Downloaded item 1234567890 to "/tmp/a" (1 bytes after 1 chunks)"#
        #expect(SteamCMDDoctorService.capturedDownloadPath(stdout: success, itemID: 999) == nil)

        let failure = "ERROR! Download item 1234567890 failed (No Connection)."
        #expect(SteamCMDDoctorService.capturedDownloadPath(stdout: failure, itemID: 1234567890) == nil)
    }
}

@Suite("SteamCMD binary resolution")
struct SteamCMDBinaryResolutionTests {

    /// Builds a Homebrew-cask-style layout in a temp dir:
    ///   root/steamcmd.wrapper.sh  (shell wrapper that exec's MacOS/steamcmd.sh)
    ///   root/MacOS/steamcmd       (Mach-O, like the cask ships)
    ///   root/bin/steamcmd         (symlink → wrapper, like /opt/homebrew/bin)
    private func makeHomebrewLayout() throws -> (root: URL, wrapper: URL, binSymlink: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lw-steamcmd-\(UUID().uuidString)", isDirectory: true)
        let macOSDir = root.appendingPathComponent("MacOS", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Mach-O magic for a 64-bit little-endian executable (0xcffaedfe).
        let machO = macOSDir.appendingPathComponent("steamcmd", isDirectory: false)
        try Data([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]).write(to: machO)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: machO.path)

        let wrapper = root.appendingPathComponent("steamcmd.wrapper.sh", isDirectory: false)
        try "#!/bin/sh\nexec '\(macOSDir.path)/steamcmd.sh' \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)

        let binSymlink = binDir.appendingPathComponent("steamcmd", isDirectory: false)
        try fm.createSymbolicLink(at: binSymlink, withDestinationURL: wrapper)
        return (root, wrapper, binSymlink)
    }

    @Test("Wrapper script resolves to the sibling MacOS/steamcmd Mach-O")
    func resolvesWrapperToMachO() throws {
        let layout = try makeHomebrewLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        guard case .success(let url) = SteamCMDBinaryResolver.resolveCanonicalBinary(at: layout.wrapper) else {
            Issue.record("Expected the wrapper to resolve to the Mach-O binary")
            return
        }
        #expect(url.path.hasSuffix("MacOS/steamcmd"))
    }

    @Test("A bin/steamcmd symlink (Homebrew-style) resolves through the wrapper")
    func resolvesSymlinkThroughWrapper() throws {
        let layout = try makeHomebrewLayout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        guard case .success(let url) = SteamCMDBinaryResolver.resolveCanonicalBinary(at: layout.binSymlink) else {
            Issue.record("Expected the symlink to resolve through the wrapper to the Mach-O")
            return
        }
        #expect(url.path.hasSuffix("MacOS/steamcmd"))
    }

    @Test("A directory is rejected, not treated as a binary")
    func rejectsDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lw-empty-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        if case .success = SteamCMDBinaryResolver.resolveCanonicalBinary(at: dir) {
            Issue.record("A directory must not resolve as a SteamCMD binary")
        }
    }
}
#endif
