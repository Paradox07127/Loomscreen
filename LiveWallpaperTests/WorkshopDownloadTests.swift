#if !LITE_BUILD && DIRECT_DISTRIBUTION
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
#endif
