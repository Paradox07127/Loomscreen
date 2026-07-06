import Foundation
import Testing
@testable import LiveWallpaper

@Suite("JSONLTailReader: incremental tailing, rotation, resync")
struct JSONLTailReaderTests {

    private func makeTempFile(_ contents: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLTailReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: text.data(using: .utf8)!)
    }

    private func linesAsStrings(_ outcome: TailPollOutcome) -> [String] {
        outcome.newLines.map { String(data: $0, encoding: .utf8) ?? "" }
    }

    @Test("first poll of a small file replays all complete lines from offset 0")
    func firstPollReplaysAll() throws {
        let url = try makeTempFile("{\"a\":1}\n{\"b\":2}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        let outcome = try reader.poll()
        #expect(linesAsStrings(outcome) == ["{\"a\":1}", "{\"b\":2}"])
        #expect(outcome.didRotate == false)
        #expect(reader.startedMidFile == false)
    }

    @Test("subsequent poll returns only newly appended lines")
    func appendDetection() throws {
        let url = try makeTempFile("{\"a\":1}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        _ = try reader.poll()

        try append("{\"b\":2}\n{\"c\":3}\n", to: url)
        let outcome = try reader.poll()
        #expect(linesAsStrings(outcome) == ["{\"b\":2}", "{\"c\":3}"])
    }

    @Test("resume continues from cursor without re-emitting prior lines")
    func resumeContinuesWithoutReemitting() throws {
        let url = try makeTempFile("{\"old\":1}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let firstReader = JSONLTailReader(url: url)
        _ = try firstReader.poll()
        guard let cursor = firstReader.cursorState else {
            Issue.record("Expected cursor after first successful poll")
            return
        }

        try append("{\"new\":2}\n", to: url)
        let resumedReader = JSONLTailReader(url: url, resumeFrom: cursor)
        let outcome = try resumedReader.poll()

        #expect(outcome.didRotate == false)
        #expect(resumedReader.startedMidFile == false)
        #expect(linesAsStrings(outcome) == ["{\"new\":2}"])
    }

    @Test("resume after rotation restarts from zero and reports rotation")
    func resumeAfterRotationRestarts() throws {
        let url = try makeTempFile("{\"old\":1}\n{\"old\":2}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let firstReader = JSONLTailReader(url: url)
        _ = try firstReader.poll()
        guard let cursor = firstReader.cursorState else {
            Issue.record("Expected cursor after first successful poll")
            return
        }

        try FileManager.default.removeItem(at: url)
        try Data("{\"fresh\":1}\n".utf8).write(to: url)

        let resumedReader = JSONLTailReader(url: url, resumeFrom: cursor)
        let outcome = try resumedReader.poll()

        #expect(outcome.didRotate == true)
        #expect(linesAsStrings(outcome) == ["{\"fresh\":1}"])
    }

    @Test("cursorState round-trips and resumes before an unfinished trailing line")
    func cursorStateRoundTrip() throws {
        let url = try makeTempFile("{\"done\":1}\n{\"partial\":")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let firstReader = JSONLTailReader(url: url)
        let firstOutcome = try firstReader.poll()
        #expect(linesAsStrings(firstOutcome) == ["{\"done\":1}"])
        guard let cursor = firstReader.cursorState else {
            Issue.record("Expected cursor after first successful poll")
            return
        }

        let encoded = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(TailCursorState.self, from: encoded)
        #expect(decoded == cursor)

        try append("true}\n", to: url)
        let resumedReader = JSONLTailReader(url: url, resumeFrom: decoded)
        let resumedOutcome = try resumedReader.poll()

        #expect(linesAsStrings(resumedOutcome) == ["{\"partial\":true}"])
    }

    @Test("a partial trailing line is held until its newline arrives")
    func halfLineHeldThenCompleted() throws {
        let url = try makeTempFile("{\"a\":1}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        _ = try reader.poll()

        // Write half a line — no trailing newline.
        try append("{\"partial\":", to: url)
        let mid = try reader.poll()
        #expect(mid.newLines.isEmpty, "partial line must not surface yet")

        // Complete it.
        try append("true}\n", to: url)
        let done = try reader.poll()
        #expect(linesAsStrings(done) == ["{\"partial\":true}"])
    }

    @Test("truncate + rewrite (size shrink) flags rotation and replays from 0")
    func rotationOnTruncate() throws {
        let url = try makeTempFile("{\"old\":1}\n{\"old\":2}\n{\"old\":3}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        _ = try reader.poll()

        // Replace with shorter content.
        try "{\"new\":1}\n".data(using: .utf8)!.write(to: url)
        let outcome = try reader.poll()
        #expect(outcome.didRotate == true)
        #expect(linesAsStrings(outcome) == ["{\"new\":1}"])
    }

    @Test("inode change (atomic replace) is treated as rotation")
    func rotationOnInodeChange() throws {
        let url = try makeTempFile("{\"a\":1}\n{\"a\":2}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        _ = try reader.poll()

        // Atomic replace: remove + recreate ⇒ new inode, even if similar size.
        try FileManager.default.removeItem(at: url)
        try "{\"fresh\":1}\n{\"fresh\":2}\n".data(using: .utf8)!.write(to: url)
        let outcome = try reader.poll()
        #expect(outcome.didRotate == true)
        #expect(linesAsStrings(outcome) == ["{\"fresh\":1}", "{\"fresh\":2}"])
    }

    @Test("vanished file reports fileVanished and resets")
    func vanishReported() throws {
        let url = try makeTempFile("{\"a\":1}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        _ = try reader.poll()

        try FileManager.default.removeItem(at: url)
        let outcome = try reader.poll()
        #expect(outcome.fileVanished == true)
        #expect(outcome.newLines.isEmpty)
    }

    @Test("oversized file starts mid-stream and only emits well-formed lines")
    func midFileStartForBigFile() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Fabricate > 20 MB so the reader skips to a tail window. Each line is a
        // small valid JSON object; padded so the file crosses the ceiling fast.
        let pad = String(repeating: "x", count: 512)
        var buffer = Data()
        let template = "{\"i\":%d,\"pad\":\"\(pad)\"}\n"
        var i = 0
        // ~21 MB worth.
        while buffer.count < 21 << 20 {
            buffer.append(String(format: template, i).data(using: .utf8)!)
            i += 1
        }
        try buffer.write(to: url)

        let reader = JSONLTailReader(url: url)
        let outcome = try reader.poll()
        #expect(reader.startedMidFile == true)
        // Every surfaced line must be a complete, parseable object (no leading
        // fragment from the mid-file seek).
        for data in outcome.newLines {
            let obj = try? JSONSerialization.jsonObject(with: data)
            #expect(obj is [String: Any], "mid-file line not well-formed: \(String(data: data, encoding: .utf8) ?? "?")")
        }
        #expect(outcome.newLines.isEmpty == false)
    }

    @Test("empty lines are skipped, not surfaced as blank entries")
    func blankLinesSkipped() throws {
        let url = try makeTempFile("{\"a\":1}\n\n{\"b\":2}\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let reader = JSONLTailReader(url: url)
        let outcome = try reader.poll()
        #expect(linesAsStrings(outcome) == ["{\"a\":1}", "{\"b\":2}"])
    }
}
