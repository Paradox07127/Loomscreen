#if !LITE_BUILD
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

    @Test("Parses streamed SteamCMD download progress")
    func parsesSteamCMDDownloadProgress() throws {
        let progress = try #require(
            SteamCMDProcessRunner.parseDownloadProgressLine(
                "Update state (0x61) downloading, progress: 42.34 (123456789 / 290000000)"
            )
        )

        #expect(abs(progress.percent - 42.34) < 0.001)
        #expect(progress.downloadedBytes == 123_456_789)
        #expect(progress.totalBytes == 290_000_000)
    }

    @Test("Ignores non-progress SteamCMD lines")
    func ignoresNonProgressSteamCMDLines() {
        #expect(SteamCMDProcessRunner.parseDownloadProgressLine("Update state (0x5) verifying install") == nil)
        #expect(SteamCMDProcessRunner.parseDownloadProgressLine("progress: nope (1 / 2)") == nil)
    }

    @Test("SteamCMD output retention is a bounded tail")
    func steamCMDOutputTailIsBounded() {
        var tail = SteamCMDOutputTail(maxBytes: 32)
        tail.append(Data("discard-me-".utf8))
        tail.append(Data("0123456789abcdefghijklmnopqrstuv-final".utf8))

        #expect(tail.retainedByteCount == 32)
        #expect(tail.discardedByteCount > 0)
        #expect(tail.string == "6789abcdefghijklmnopqrstuv-final")
    }

    @Test("SteamCMD output tail stays bounded across 100 MiB of streamed chunks")
    func steamCMDOutputTailStaysBoundedForHostileOutput() {
        let limit = 1 << 20
        let chunk = Data(repeating: 0x41, count: limit)
        var tail = SteamCMDOutputTail(maxBytes: limit)

        for _ in 0..<100 {
            tail.append(chunk)
            #expect(tail.retainedByteCount <= limit)
        }
        tail.append(Data("FINAL-DIAGNOSTIC".utf8))

        #expect(tail.retainedByteCount == limit)
        #expect(tail.discardedByteCount > 99 * limit)
        #expect(tail.string.hasSuffix("FINAL-DIAGNOSTIC"))
    }

    @Test("SteamCMD output tail has fixed capacity under one-byte chunks")
    func steamCMDOutputTailHandlesTinyChunks() {
        var tail = SteamCMDOutputTail(maxBytes: 1_024)
        for value in 0..<250_000 {
            tail.append(Data([UInt8(truncatingIfNeeded: value)]))
        }

        #expect(tail.retainedByteCount == 1_024)
        #expect(tail.data.count == 1_024)
        #expect(tail.discardedByteCount == 250_000 - 1_024)
    }

    @Test("SteamCMD semantic facts survive diagnostic-tail eviction")
    func steamCMDSemanticFactsSurviveTailEviction() {
        var summary = SteamCMDOutputSemanticSummary()
        summary.consume("Steam Console Client (c) Valve Corporation - version 1700000000")
        summary.consume(#"Success. Downloaded item 123 to "/tmp/item""#)
        var tail = SteamCMDOutputTail(maxBytes: 32)
        tail.append(Data(repeating: 0x78, count: 4_096))

        let output = summary.rendered(with: tail)
        #expect(output.contains("Steam Console Client (c) Valve Corporation"))
        #expect(output.contains("Success. Downloaded item 123"))
        #expect(output.contains("output bytes omitted"))
    }

    @Test("SteamCMD public build id survives diagnostic-tail eviction")
    func steamCMDPublicBuildIDSurvivesTailEviction() {
        var summary = SteamCMDOutputSemanticSummary()
        summary.consume(#"    "public""#)
        summary.consume("    {")
        summary.consume(#"        "buildid"    "24681012""#)
        summary.consume("    }")
        var tail = SteamCMDOutputTail(maxBytes: 32)
        tail.append(Data(repeating: 0x78, count: 4_096))

        let output = summary.rendered(with: tail)
        #expect(SteamCMDDoctorService.parsePublicBuildID(fromAppInfo: output) == "24681012")
    }

    @Test("Repeated public contexts cannot exhaust independent semantic slots")
    func repeatedPublicContextsCannotExhaustSemanticSlots() {
        var summary = SteamCMDOutputSemanticSummary()
        for value in 0..<1_000 {
            summary.consume(#""public""#)
            summary.consume(#""buildid" "\#(value)""#)
        }
        summary.consume("Steam Console Client (c) Valve Corporation - version 1700000000")
        summary.consume(#"Success. Downloaded item 123 to "/tmp/item""#)
        var tail = SteamCMDOutputTail(maxBytes: 16)
        tail.append(Data(repeating: 0x78, count: 1_024))

        let output = summary.rendered(with: tail)
        #expect(output.contains("Steam Console Client (c) Valve Corporation"))
        #expect(output.contains("Success. Downloaded item 123"))
    }
}

@Suite("SteamCMD binary resolution")
struct SteamCMDBinaryResolutionTests {

    private func makeHomebrewLayout() throws -> (root: URL, wrapper: URL, binSymlink: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lw-steamcmd-\(UUID().uuidString)", isDirectory: true)
        let macOSDir = root.appendingPathComponent("MacOS", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

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
