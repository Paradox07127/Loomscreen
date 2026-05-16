import Foundation
import Testing
@testable import LiveWallpaper

struct WPEResolutionDiagnosticsTests {

    @Test("Records scene miss then built-in hit")
    func recordsBuiltinHitAfterSceneMiss() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
        }
        try write("sentinel", relativePath: "models/util/foo.json", under: builtins)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer,
            builtinRootURL: builtins
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "models/util/foo.json")

        #expect(url.lastPathComponent == "foo.json")
        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 1)
        let event = try #require(snapshot.events.first)
        #expect(event.ref == "models/util/foo.json")
        #expect(event.attempts == [
            WPEResolutionAttempt(origin: .scene, outcome: .fileMissing),
            WPEResolutionAttempt(origin: .builtin, outcome: .resolved)
        ])
        #expect(event.finalOutcome == .resolved)
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.resolvedByOrigin[.builtin] == 1)
    }

    @Test("Records every root miss for unresolved ref")
    func recordsAllRootMisses() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        let engine = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
            try? FileManager.default.removeItem(at: engine)
        }

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            engineAssetsRootURL: engine,
            tracer: tracer,
            builtinRootURL: builtins
        )

        #expect(throws: SceneResourceResolver.ResolveError.self) {
            _ = try resolver.resolveExistingFileURL(relativePath: "models/util/missing.json")
        }

        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 1)
        let event = try #require(snapshot.events.first)
        #expect(event.ref == "models/util/missing.json")
        #expect(event.attempts == [
            WPEResolutionAttempt(origin: .scene, outcome: .fileMissing),
            WPEResolutionAttempt(origin: .builtin, outcome: .fileMissing),
            WPEResolutionAttempt(origin: .engineAssets, outcome: .fileMissing)
        ])
        #expect(event.finalOutcome == .fileMissing)
        #expect(snapshot.missedRefs == [event])
    }

    @Test("Records dependency mount resolution")
    func recordsDependencyResolution() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        let dependency = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
            try? FileManager.default.removeItem(at: dependency)
        }
        try write("dependency", relativePath: "X", under: dependency)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [WPEAssetMount(workshopID: "12345", rootURL: dependency)],
            tracer: tracer,
            builtinRootURL: builtins
        )

        let url = try resolver.resolveExistingFileURL(relativePath: "../12345/X")

        #expect(url.lastPathComponent == "X")
        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 1)
        let event = try #require(snapshot.events.first)
        #expect(event.ref == "../12345/X")
        #expect(event.attempts == [
            WPEResolutionAttempt(origin: .dependency("12345"), outcome: .resolved)
        ])
        #expect(event.finalOutcome == .resolved)
        #expect(snapshot.resolvedByOrigin[.dependency("12345")] == 1)
    }

    @Test("Tracer reset clears events")
    func resetClearsEvents() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
        }
        try write("x", relativePath: "x.json", under: builtins)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer,
            builtinRootURL: builtins
        )

        _ = try resolver.resolveExistingFileURL(relativePath: "x.json")
        #expect(tracer.snapshot().events.count == 1)
        tracer.reset()
        #expect(tracer.snapshot().events.isEmpty)
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-resolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ payload: String, relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(payload.utf8).write(to: url)
    }
}
