import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Logging privacy boundary")
struct LogPrivacyBoundaryTests {
    private let sensitive = """
    phase=parse code=42 GET https://alice:s3cret@api.example.com/scene?id=7&token=abc123 \
    path=/Users/alice/Movies/private.wallpaper Authorization: Bearer header.payload.sig
    """

    @Test("Logger strips secrets while retaining stable diagnostics")
    func loggerBoundaryRedactsSensitiveFields() {
        let output = Logger.sanitizedBody(sensitive)

        #expect(!output.contains("alice"))
        #expect(!output.contains("s3cret"))
        #expect(!output.contains("abc123"))
        #expect(!output.contains("header.payload.sig"))
        #expect(output.contains("api.example.com"))
        #expect(output.contains("phase=parse"))
        #expect(output.contains("code=42"))
        #expect(output.contains("private.wallpaper"))
    }

    @Test("Persistent sink applies the same redaction defensively")
    func persistentSinkUsesSameBoundary() {
        #expect(LogFileSink.sanitizedMessage(sensitive) == Logger.sanitizedBody(sensitive))
    }

    @Test("Persistent file and diagnostic export contain only redacted content")
    func persistentFileRoundTripIsRedacted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogPrivacyBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("runtime.log")
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let sink = LogFileSink(fileURL: file)
        sink.record(
            category: .fileAccess,
            level: .error,
            message: sensitive,
            file: "/source/ResourceUtilities.swift",
            line: 42
        )

        let persisted = try String(contentsOf: file, encoding: .utf8)
        let exported = sink.recentDiagnosticLines().joined(separator: "\n")
        for output in [persisted, exported] {
            #expect(!output.contains("alice"))
            #expect(!output.contains("s3cret"))
            #expect(!output.contains("abc123"))
            #expect(output.contains("phase=parse"))
            #expect(output.contains("code=42"))
        }
    }

    @Test("Redaction is idempotent")
    func redactionIsIdempotent() {
        let once = LogPrivacyRedactor.scrub(sensitive)
        #expect(LogPrivacyRedactor.scrub(once) == once)
    }

    @Test("NSError metadata allowlists keys but never values")
    func errorMetadataDoesNotRenderUserInfoValues() {
        let error = NSError(
            domain: "LogPrivacyTest",
            code: 77,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: "livewallpaper://wallpaper/index.html?n=nonce-secret",
                NSFilePathErrorKey: "/Users/alice/private.scene",
                "token": "api-secret"
            ]
        )
        let output = ResourceUtilities.safeErrorMetadata(error)

        #expect(output.contains("domain=LogPrivacyTest"))
        #expect(output.contains("code=77"))
        #expect(output.contains("contextKeys="))
        #expect(!output.contains("nonce-secret"))
        #expect(!output.contains("/Users/alice"))
        #expect(!output.contains("api-secret"))
    }
}
