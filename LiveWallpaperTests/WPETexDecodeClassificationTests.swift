#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

/// One-time diagnostic harness for scoping animated `.tex` decode work
/// (Phase 0 of `.claude/plan/wpe-animated-tex-scope.md`). Read-only: it never
/// binds GPU resources or mutates product state — it only runs both decode
/// paths over every `.tex` in a scene package and classifies the outcome.
///
/// The decision gate is the `genuine_eager_failure:*` bucket — those are the
/// only `.tex` files that represent a real "missing texture / black layer"
/// gap. Everything else means the eager path already loads the texture, so
/// remaining animated-TEXS work is fidelity/perf, not correctness.
///
/// Opt in with:
///
///     WPE_CORPUS_ROOT="/path/to/431960" \
///     WPE_TEX_SCAN_WORKSHOP_ID="3554161528" \
///     xcodebuild test -only-testing:LiveWallpaperTests/WPETexDecodeClassificationTests
///
/// If `WPE_CORPUS_ROOT` is unset, the harness probes the local corpus-cache
/// default and skips cleanly when it is not readable (keeps CI green).
struct WPETexDecodeClassificationTests {
    private static let defaultCorpusRoot = "/private/tmp/loomscreen-wpe-corpus-root"
    private static let defaultWorkshopID = "3554161528"

    @Test("Classifies lazy versus eager TEX decode outcomes for one scene package")
    func classifiesScenePackageTexDecodeOutcomes() async throws {
        let env = ProcessInfo.processInfo.environment
        let rawRoot = env["WPE_CORPUS_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultCorpusRoot
        let workshopID = env["WPE_TEX_SCAN_WORKSHOP_ID"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultWorkshopID

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
        let probeOK = await Self.probeReadable(root, timeoutSeconds: 2)
        guard probeOK else {
            print("[tex-scan] corpus root '\(rawRoot)' is not readable — skipping")
            return
        }

        let sceneRoot = root.appendingPathComponent(workshopID, isDirectory: true)
        let pkgURL = sceneRoot.appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: pkgURL.path) else {
            print("[tex-scan] scene.pkg not found for workshop \(workshopID) at \(pkgURL.path) — skipping")
            return
        }

        let safeWorkshopID = workshopID.replacingOccurrences(of: "/", with: "_")
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("wpe-tex-scan-\(safeWorkshopID)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let handle = try FileHandle(forReadingFrom: pkgURL)
        defer { try? handle.close() }
        let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        try package.extractAll(streamingFrom: handle, to: stage)

        let texFiles = try Self.texFiles(in: stage)
        let decoder = WPETexDecoder()
        var reports: [TexReport] = []
        reports.reserveCapacity(texFiles.count)

        for url in texFiles {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let lazy = decoder.extractStreamingPayload(data: data)
            let eager = decoder.extractTexturePayload(data: data)
            let eagerFields = Self.eagerFields(from: eager)
            reports.append(TexReport(
                path: Self.relativePath(for: url, under: stage),
                byteSize: data.count,
                bucket: Self.bucket(lazy: lazy, eager: eager),
                lazyOutcome: Self.lazyDescription(lazy),
                eagerMipmapCount: eagerFields.mipmapCount,
                eagerHasAnimationFrames: eagerFields.hasAnimationFrames,
                eagerHasAnimationTrack: eagerFields.hasAnimationTrack,
                eagerHasVideoPayload: eagerFields.hasVideoPayload
            ))
        }

        Self.printSummary(reports: reports, workshopID: workshopID)
        #expect(
            reports.count == texFiles.count,
            "Every discovered .tex file should have exactly one classification"
        )
    }

    private struct TexReport {
        let path: String
        let byteSize: Int
        let bucket: String
        let lazyOutcome: String
        let eagerMipmapCount: String
        let eagerHasAnimationFrames: String
        let eagerHasAnimationTrack: String
        let eagerHasVideoPayload: String
    }

    /// Single source of truth for the Phase 0 decision gate. Buckets:
    ///   - `genuine_eager_failure:<err>` — the eager Metal path failed. The
    ///     ONLY bucket that signals a real black/missing-layer gap.
    ///   - `video_payload`               — eager surfaced an embedded video (MP4).
    ///   - `lazy_eligible_success`       — multi-frame; both lazy + eager succeed.
    ///   - `benign_lazy_skip_eager_animated` — lazy declined (`unsupportedAnimation`)
    ///     but eager still produced animation frames (encoded/atlas animation
    ///     the lazy streamer can't carry; eager covers it).
    ///   - `benign_lazy_skip_static`     — lazy declined; eager produced a plain
    ///     single-frame static texture. The overwhelmingly common benign case.
    ///   - `eager_success_lazy_other_failure:<err>` — lazy declined for a
    ///     non-animation reason yet eager succeeded; surfaced distinctly so it
    ///     isn't silently folded into the benign buckets.
    private static func bucket(
        lazy: Result<WPETexStreamingPayload, WPETexDecodeError>,
        eager: Result<WPETexTexturePayload, WPETexDecodeError>
    ) -> String {
        switch eager {
        case .failure(let error):
            return "genuine_eager_failure:\(describe(error))"

        case .success(let payload):
            if payload.videoPayload != nil {
                return "video_payload"
            }
            switch lazy {
            case .success:
                return "lazy_eligible_success"
            case .failure(.unsupportedAnimation):
                return payload.hasAnimationFrames
                    ? "benign_lazy_skip_eager_animated"
                    : "benign_lazy_skip_static"
            case .failure(let error):
                return "eager_success_lazy_other_failure:\(describe(error))"
            }
        }
    }

    private static func eagerFields(
        from result: Result<WPETexTexturePayload, WPETexDecodeError>
    ) -> (
        mipmapCount: String,
        hasAnimationFrames: String,
        hasAnimationTrack: String,
        hasVideoPayload: String
    ) {
        switch result {
        case .success(let payload):
            return (
                String(payload.mipmaps.count),
                String(payload.hasAnimationFrames),
                String(payload.animationTrack != nil),
                String(payload.videoPayload != nil)
            )
        case .failure:
            return ("n/a", "n/a", "n/a", "n/a")
        }
    }

    private static func lazyDescription(
        _ result: Result<WPETexStreamingPayload, WPETexDecodeError>
    ) -> String {
        switch result {
        case .success(let payload):
            return "success(rawBytes=\(payload.totalUncompressedImageBytes), images=\(payload.compressedImages.count), frames=\(payload.frames.count))"
        case .failure(let error):
            return "failure(\(describe(error)))"
        }
    }

    private static func describe(_ error: WPETexDecodeError) -> String {
        String(describing: error)
    }

    private static func printSummary(reports: [TexReport], workshopID: String) {
        let counts = Dictionary(grouping: reports, by: \.bucket).mapValues(\.count)
        let genuineFailures = reports.filter { $0.bucket.hasPrefix("genuine_eager_failure") }.count

        print("=== WPE TEX decode classification: \(workshopID) ===")
        print("Total .tex files: \(reports.count)")
        print("DECISION GATE — genuine_eager_failure count: \(genuineFailures)")
        print("Buckets:")
        for bucket in counts.keys.sorted() {
            print("  \(bucket): \(counts[bucket] ?? 0)")
        }
        print("")
        print("path\tbucket\tbytes\teagerMipmaps\thasAnimationFrames\thasAnimationTrack\thasVideoPayload\tlazyOutcome")
        for report in reports.sorted(by: { $0.path < $1.path }) {
            print("\(report.path)\t\(report.bucket)\t\(report.byteSize)\t\(report.eagerMipmapCount)\t\(report.eagerHasAnimationFrames)\t\(report.eagerHasAnimationTrack)\t\(report.eagerHasVideoPayload)\t\(report.lazyOutcome)")
        }
    }

    private static func texFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "tex" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
    }

    /// Sandbox-safe directory probe, mirrored from `WPEEndToEndCorpusTests`.
    static func probeReadable(_ url: URL, timeoutSeconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )) != nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return false
        }
    }
}
#endif
