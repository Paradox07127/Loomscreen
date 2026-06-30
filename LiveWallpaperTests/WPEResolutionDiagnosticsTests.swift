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

    @Test("Speculative streaming decline is not a miss once the ref resolves eagerly")
    func speculativeStreamingDeclineDoesNotCountAsMiss() {
        // The renderer probes the lazy-streaming path before the eager static
        // path. Single-frame static `.tex` decline streaming with
        // `unsupportedAnimation` (lazy = animation-only) and then resolve
        // eagerly — they must not be reported missing. (saber 3526278753:
        // 9 such textures were spuriously counted as `missing`.)
        let ref = "materials/util/clouds_256.tex"
        let tracer = WPEResolutionTracer()
        tracer.record(WPEResolutionEvent(
            ref: ref,
            attempts: [WPEResolutionAttempt(
                origin: .scene,
                outcome: .otherError("texture(unsupportedAnimation)")
            )],
            finalOutcome: .otherError("texture(unsupportedAnimation)")
        ))
        tracer.record(WPEResolutionEvent(
            ref: ref,
            attempts: [WPEResolutionAttempt(origin: .scene, outcome: .resolved)],
            finalOutcome: .resolved
        ))

        let snapshot = tracer.snapshot()
        #expect(snapshot.events.count == 2)
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
    }

    @Test("A ref that never resolves is still reported missing")
    func unresolvedRefStaysMissing() {
        let tracer = WPEResolutionTracer()
        tracer.record(WPEResolutionEvent(
            ref: "materials/ghost.tex",
            attempts: [WPEResolutionAttempt(origin: .scene, outcome: .fileMissing)],
            finalOutcome: .fileMissing
        ))

        let snapshot = tracer.snapshot()
        #expect(snapshot.missedRefs.map(\.ref) == ["materials/ghost.tex"])
    }

    // Integration: mirror the renderer's two-step texture load
    // (`resolveStreamingPayloadIfHeavy` speculative probe → eager
    // `resolveTexturePayload`) over a real single-frame static `.tex` and
    // confirm the tracer reports it resolved, not missing. This is the
    // hermetic stand-in for saber 3526278753's resolution-summary going
    // missing=9 → 0.
    @Test("Single-frame static .tex resolves through the real resolver without a spurious miss")
    func singleFrameStaticTexResolvesWithoutSpuriousMiss() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
        }
        let texPath = "materials/util/black.tex"
        try writeData(
            Self.singleFrameStaticTex(width: 32, height: 32),
            relativePath: texPath,
            under: primary
        )

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer,
            builtinRootURL: builtins
        )

        // Speculative lazy-streaming probe declines single-frame static with
        // `unsupportedAnimation` (the renderer swallows this); eager path resolves it.
        #expect(throws: SceneResourceResolver.ResolveError.texture(.unsupportedAnimation)) {
            _ = try resolver.resolveStreamingTexturePayload(relativePath: texPath)
        }
        let payload = try resolver.resolveTexturePayload(relativePath: texPath)
        #expect(payload.largestMipmap?.width == 32)
        #expect(payload.largestMipmap?.height == 32)

        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty, "speculative streaming decline must not count as a miss")
    }

    @Test("Built-in raster sibling resolves tex-named util image refs")
    func builtinRasterSiblingResolvesTexNamedUtilRefs() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
        }
        try writeData(Self.onePixelPNG, relativePath: "materials/util/white.png", under: builtins)

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer,
            builtinRootURL: builtins
        )

        let image = try resolver.resolveImage(relativePath: "materials/util/white.tex")

        #expect(image.width == 1)
        #expect(image.height == 1)
        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
    }

    @Test("Workshop raw image ref stored as converted material tex resolves without miss")
    func workshopRawImageRefStoredAsConvertedMaterialTexResolvesWithoutMiss() throws {
        let primary = try makeTempRoot()
        let builtins = try makeTempRoot()
        defer {
            try? FileManager.default.removeItem(at: primary)
            try? FileManager.default.removeItem(at: builtins)
        }
        let rawRef = "workshop/2328851328/particle/雪花.jpg"
        try writeData(
            Self.singleFrameStaticTex(width: 4, height: 4),
            relativePath: "materials/\(rawRef).tex",
            under: primary
        )

        let tracer = WPEResolutionTracer()
        let resolver = WPEMultiRootResourceResolver(
            primaryRootURL: primary,
            dependencyMounts: [],
            tracer: tracer,
            builtinRootURL: builtins
        )

        let image = try resolver.resolveImage(relativePath: rawRef)

        #expect(image.width == 4)
        #expect(image.height == 4)
        let snapshot = tracer.snapshot()
        #expect(snapshot.resolvedCount == 1)
        #expect(snapshot.missedRefs.isEmpty)
        #expect(snapshot.events.first?.ref == rawRef)
        #expect(snapshot.events.first?.attempts == [
            WPEResolutionAttempt(origin: .scene, outcome: .resolved)
        ])
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
        try writeData(Data(payload.utf8), relativePath: relativePath, under: root)
    }

    private func writeData(_ data: Data, relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// One RGBA8888 image, one mipmap, no TEXS schedule — the shape of
    /// util/black, util/clouds_256 and the saber mask textures.
    private static func singleFrameStaticTex(width: Int, height: Int) -> Data {
        var buffer = Data()
        func magic(_ value: String) {
            buffer.append(contentsOf: value.utf8)
            buffer.append(0x00)
        }
        func int32(_ value: Int32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { buffer.append(contentsOf: $0) }
        }
        func uint32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { buffer.append(contentsOf: $0) }
        }

        magic("TEXV0005")
        magic("TEXI0001")
        int32(Int32(WPETexFormat.rgba8888.rawValue))
        uint32(0)
        int32(Int32(width))
        int32(Int32(height))
        int32(Int32(width))
        int32(Int32(height))
        int32(0)

        magic("TEXB0003")
        int32(1)            // imageCount
        int32(-1)           // sourceImageFormat (-1 = raw, not a FreeImage payload)
        int32(1)            // mipmapCount
        int32(Int32(width))
        int32(Int32(height))
        let pixels = width * height * 4
        uint32(0)           // not compressed
        uint32(UInt32(pixels))
        uint32(UInt32(pixels))
        buffer.append(Data(repeating: 0x00, count: pixels))
        return buffer
    }

    private static let onePixelPNG = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=
    """)!
}
