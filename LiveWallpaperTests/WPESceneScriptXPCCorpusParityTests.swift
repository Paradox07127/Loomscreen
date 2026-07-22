#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
@testable import LiveWallpaper
import Testing

@Suite(.serialized)
struct WPESceneScriptXPCCorpusParityTests {
    @Test("Classifier covers every folder and emits deterministic path-redacted JSON")
    func classifierAndReportFixture() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("scenescript-xpc-corpus-fixture-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeProject(
            id: "001",
            type: "scene",
            entryFile: "scene.json",
            sceneData: Self.sceneJSON(origin: "0 0 0"),
            root: root
        )
        try Self.writeProject(
            id: "002",
            type: "scene",
            entryFile: "scene.json",
            sceneData: Self.sceneJSON(origin: [
                "script": "export function update(value) { value.x = 12; return value; }",
                "value": "0 0 0",
            ]),
            root: root
        )
        try Self.writeProject(
            id: "003",
            type: "scene",
            entryFile: "scene.json",
            sceneData: Data("{".utf8),
            root: root
        )
        try Self.writeProject(
            id: "004",
            type: "scene",
            entryFile: "missing.json",
            root: root
        )
        try Self.writeProject(
            id: "005",
            type: "web",
            entryFile: "index.html",
            sceneData: Data("ok".utf8),
            root: root
        )
        let malformed = root.appendingPathComponent("006", isDirectory: true)
        try fileManager.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: malformed.appendingPathComponent("project.json"))

        let report = try await SceneScriptXPCCorpusParityRunner.run(
            root: root,
            rootLabel: "deterministic-fixture",
            candidateRoute: .inProcess
        )
        #expect(report.entries.map(\.folderID) == ["001", "002", "003", "004", "005", "006"])
        #expect(report.entries.map(\.classification) == [
            .noStaticTransformScripts,
            .exact,
            .parseFailure,
            .extractionFailure,
            .notSceneProject,
            .projectManifestFailure,
        ])
        #expect(report.summary.folderCount == 6)
        #expect(report.summary.sceneProjectCount == 4)
        #expect(report.summary.staticScriptSceneCount == 1)
        #expect(report.summary.staticTransformScriptCount == 1)

        let first = try report.encoded()
        let second = try report.encoded()
        #expect(first == second)
        #expect(first.range(of: Data(root.path.utf8)) == nil)
        #expect(first.range(of: Data("export function".utf8)) == nil)
        let keys = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(Set(keys.keys) == ["schema", "runClassification", "summary", "entries"])
    }

    @Test("Signed host compares the full configured corpus against the embedded helper")
    func signedHostCorpusParity() async throws {
        #expect(WPETransformScriptEvaluator.hostIsApplicationBundle)
        #expect(WPESceneScriptXPCClient.shared.isEmbeddedServiceAvailable)

        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("LiveWallpaper", isDirectory: true)
        let outputDirectory = support.appendingPathComponent("oracle-out", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent(
            "scenescript-xpc-corpus-parity-v1.json"
        )

        guard let selection = try Self.corpusSelection(support: support) else {
            let report = SceneScriptXPCCorpusParityReport.unavailable
            try report.encoded().write(to: outputURL, options: .atomic)
            print("[scenescript-xpc-corpus] realCorpusExecuted=false classification=corpusUnavailable")
            print("[scenescript-xpc-corpus] wrote scenescript-xpc-corpus-parity-v1.json")
            return
        }

        guard let readiness = Self.waitForHelperReadiness(
            WPESceneScriptXPCClient.shared,
            timeout: .seconds(16)
        ) else {
            let report = SceneScriptXPCCorpusParityReport.serviceUnavailable
            try report.encoded().write(to: outputURL, options: .atomic)
            print("[scenescript-xpc-corpus] realCorpusExecuted=false classification=serviceUnavailable")
            print("[scenescript-xpc-corpus] wrote scenescript-xpc-corpus-parity-v1.json")
            Issue.record("Embedded SceneScript helper did not become ready within the bounded recovery gate")
            return
        }
        print("[scenescript-xpc-corpus] helperReady=true readinessProbes=\(readiness.probeCount)")

        let report = try await SceneScriptXPCCorpusParityRunner.run(
            root: selection.root,
            rootLabel: selection.label,
            candidateRoute: .helperService
        )
        try report.encoded().write(to: outputURL, options: .atomic)
        let failures = report.entries.filter(\.classification.isFailure)
        print(
            "[scenescript-xpc-corpus] realCorpusExecuted=true folders=\(report.summary.folderCount) "
                + "scenes=\(report.summary.sceneProjectCount) "
                + "staticScenes=\(report.summary.staticScriptSceneCount) "
                + "staticScripts=\(report.summary.staticTransformScriptCount) "
                + "exact=\(report.summary.classificationCounts[SceneScriptXPCCorpusClassification.exact.rawValue, default: 0]) "
                + "failures=\(failures.count)"
        )
        if !failures.isEmpty {
            print("[scenescript-xpc-corpus] mismatchCounts=" + failures.map {
                "\($0.folderID):o\($0.oracleResolvedTransformCount)/c\($0.candidateResolvedTransformCount)/d\($0.differingTransformCount)"
            }.joined(separator: ","))
        }
        print("[scenescript-xpc-corpus] wrote scenescript-xpc-corpus-parity-v1.json")
        #expect(
            failures.isEmpty,
            Comment(rawValue: "SceneScript helper corpus failures: "
                + failures.map { "\($0.folderID):\($0.classification.rawValue)" }.joined(separator: ","))
        )
    }

    private static func corpusSelection(support: URL) throws -> (root: URL, label: String)? {
        let fileManager = FileManager.default
        let configURL = support.appendingPathComponent("oracle-capture.json")
        if fileManager.fileExists(atPath: configURL.path) {
            struct Config: Decodable { let corpusRoot: String }
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
            try #require(!config.corpusRoot.isEmpty, "oracle-capture.json corpusRoot must not be empty")
            return (URL(fileURLWithPath: config.corpusRoot, isDirectory: true), "oracle-capture-config")
        }
        let canonical = support
            .deletingLastPathComponent()
            .appendingPathComponent("Steam", isDirectory: true)
            .appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
        return fileManager.fileExists(atPath: canonical.path)
            ? (canonical, "canonical-container-431960")
            : nil
    }

    private static func waitForHelperReadiness(
        _ client: WPESceneScriptXPCClient,
        timeout: Duration
    ) -> HelperReadiness? {
        let expected = SIMD3<Double>(321, 2, 3)
        let zeroWorkerID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var probeCount = 0
        while clock.now < deadline {
            probeCount += 1
            let result = client.evaluateStaticTransforms(
                canvasWidth: 100,
                canvasHeight: 100,
                requests: [
                    .init(
                        script: "export function update(value) { value.x = 321; return value; }",
                        properties: [:],
                        seed: .init(1, 2, 3)
                    )
                ],
                evaluationBudget: 0.5
            )
            if case .completed(let completion) = result,
               completion.values == [expected],
               completion.workerInstanceID != zeroWorkerID,
               completion.workerPID > 0,
               completion.durationNanoseconds > 0 {
                return .init(probeCount: probeCount)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private struct HelperReadiness {
        let probeCount: Int
    }

    private static func sceneJSON(origin: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [[
                "id": 1,
                "name": "fixture",
                "image": "fixture.png",
                "origin": origin,
            ]],
        ], options: [.sortedKeys])
    }

    private static func writeProject(
        id: String,
        type: String,
        entryFile: String,
        sceneData: Data? = nil,
        root: URL
    ) throws {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try JSONSerialization.data(withJSONObject: [
            "workshopid": id,
            "title": "fixture",
            "type": type,
            "file": entryFile,
        ], options: [.sortedKeys])
        try project.write(to: folder.appendingPathComponent("project.json"))
        if let sceneData {
            try sceneData.write(to: folder.appendingPathComponent(entryFile))
        }
    }
}

private enum SceneScriptXPCCorpusParityRunner {
    static func run(
        root: URL,
        rootLabel: String,
        candidateRoute: WPETransformScriptEvaluator.StaticTransformExecutionRoute
    ) async throws -> SceneScriptXPCCorpusParityReport {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try #require(values.isDirectory == true && values.isSymbolicLink != true,
                     "configured corpus root must be a non-symlink directory")
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { folder in
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!folders.isEmpty, "configured corpus contains no project folders")

        var entries: [SceneScriptXPCCorpusParityReport.Entry] = []
        entries.reserveCapacity(folders.count)
        for folder in folders {
            entries.append(await classify(folder: folder, candidateRoute: candidateRoute))
        }
        return SceneScriptXPCCorpusParityReport(
            schema: SceneScriptXPCCorpusParityReport.schemaVersion,
            runClassification: .completed,
            summary: .init(entries: entries),
            entries: entries
        )
    }

    private static func classify(
        folder: URL,
        candidateRoute: WPETransformScriptEvaluator.StaticTransformExecutionRoute
    ) async -> SceneScriptXPCCorpusParityReport.Entry {
        let folderID = safeID(folder.lastPathComponent)
        let project: WallpaperEngineProject
        do {
            project = try WallpaperEngineProject.read(from: folder)
        } catch {
            return .init(folderID: folderID, sceneID: nil, classification: .projectManifestFailure)
        }
        guard project.type == .scene else {
            return .init(folderID: folderID, sceneID: safeID(project.workshopID), classification: .notSceneProject)
        }

        let data: Data
        do {
            let packageURL = folder.appendingPathComponent("scene.pkg")
            if FileManager.default.fileExists(atPath: packageURL.path) {
                let provider = try await WPEPackageSceneAssetProvider.open(packageURL: packageURL)
                data = try provider.data(atRelativePath: project.entryFile)
            } else {
                data = try WPEDirectorySceneAssetProvider(rootURL: folder)
                    .data(atRelativePath: project.entryFile)
            }
        } catch {
            return .init(
                folderID: folderID,
                sceneID: safeID(project.workshopID),
                classification: .extractionFailure
            )
        }

        let oracle: ParseCapture
        do {
            oracle = try parse(data: data, route: .inProcess)
        } catch {
            return .init(
                folderID: folderID,
                sceneID: safeID(project.workshopID),
                classification: .parseFailure
            )
        }
        guard oracle.requestCount > 0 else {
            return .init(
                folderID: folderID,
                sceneID: safeID(project.workshopID),
                classification: .noStaticTransformScripts
            )
        }

        let candidate: ParseCapture
        do {
            candidate = try parse(data: data, route: candidateRoute)
        } catch {
            return .init(
                folderID: folderID,
                sceneID: safeID(project.workshopID),
                staticTransformScriptCount: oracle.requestCount,
                uniqueStaticTransformScriptSourceCount: oracle.uniqueSourceCount,
                classification: .parseFailure
            )
        }
        let exact = candidate.requestCount == oracle.requestCount
            && candidate.uniqueSourceCount == oracle.uniqueSourceCount
            && candidate.outputs == oracle.outputs
        return .init(
            folderID: folderID,
            sceneID: safeID(project.workshopID),
            staticTransformScriptCount: oracle.requestCount,
            uniqueStaticTransformScriptSourceCount: oracle.uniqueSourceCount,
            oracleResolvedTransformCount: oracle.outputs.compactMap { $0 }.count,
            candidateResolvedTransformCount: candidate.outputs.compactMap { $0 }.count,
            differingTransformCount: zip(oracle.outputs, candidate.outputs).filter { pair in
                pair.0 != pair.1
            }.count,
            classification: exact ? .exact : .mismatch
        )
    }

    private static func parse(
        data: Data,
        route: WPETransformScriptEvaluator.StaticTransformExecutionRoute
    ) throws -> ParseCapture {
        var recordingResolver: RecordingTransformResolver?
        _ = try WPESceneDocumentParser.parse(data: data, userValues: [:]) { width, height in
            let resolver = RecordingTransformResolver(
                evaluator: WPETransformScriptEvaluator(
                    canvasWidth: width,
                    canvasHeight: height,
                    governor: WPESceneScriptExecutionGovernor(limit: 4),
                    testingExecutionRoute: route
                )
            )
            recordingResolver = resolver
            return resolver
        }
        return ParseCapture(
            requestCount: recordingResolver?.requestCount ?? 0,
            uniqueSourceCount: recordingResolver?.uniqueSourceCount ?? 0,
            outputs: recordingResolver?.outputs ?? []
        )
    }

    private static func safeID(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return "redacted-unsafe-id"
        }
        return value
    }

    private struct ParseCapture {
        let requestCount: Int
        let uniqueSourceCount: Int
        let outputs: [SIMD3<Double>?]
    }

    private final class RecordingTransformResolver: WPESceneTransformScriptResolving, @unchecked Sendable {
        private let evaluator: WPETransformScriptEvaluator
        private(set) var requestCount = 0
        private var sources: Set<String> = []
        var uniqueSourceCount: Int { sources.count }
        private(set) var outputs: [SIMD3<Double>?] = []

        init(evaluator: WPETransformScriptEvaluator) {
            self.evaluator = evaluator
        }

        func resolveVec3(
            script: String,
            properties: [String: WPESceneScriptPropertyValue],
            seed: SIMD3<Double>
        ) -> SIMD3<Double>? {
            resolveBatch([.init(script: script, properties: properties, seed: seed)]).first ?? nil
        }

        func resolveBatch(_ requests: [WPESceneTransformScriptRequest]) -> [SIMD3<Double>?] {
            requestCount += requests.count
            sources.formUnion(requests.map(\.script))
            let batch = evaluator.resolveBatch(requests)
            outputs.append(contentsOf: batch)
            return batch
        }
    }
}

private struct SceneScriptXPCCorpusParityReport: Codable, Equatable {
    static let schemaVersion = "wpe.scenescript-xpc-corpus-parity.v1"

    let schema: String
    let runClassification: SceneScriptXPCCorpusRunClassification
    let summary: Summary
    let entries: [Entry]

    static let unavailable = Self(
        schema: schemaVersion,
        runClassification: .corpusUnavailable,
        summary: .init(entries: []),
        entries: []
    )

    static let serviceUnavailable = Self(
        schema: schemaVersion,
        runClassification: .serviceUnavailable,
        summary: .init(entries: []),
        entries: []
    )

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    struct Entry: Codable, Equatable {
        let folderID: String
        let sceneID: String?
        var staticTransformScriptCount = 0
        var uniqueStaticTransformScriptSourceCount = 0
        var oracleResolvedTransformCount = 0
        var candidateResolvedTransformCount = 0
        var differingTransformCount = 0
        let classification: SceneScriptXPCCorpusClassification
    }

    struct Summary: Codable, Equatable {
        let folderCount: Int
        let sceneProjectCount: Int
        let staticScriptSceneCount: Int
        let staticTransformScriptCount: Int
        let uniqueStaticTransformScriptSourceCount: Int
        let classificationCounts: [String: Int]

        init(entries: [Entry]) {
            folderCount = entries.count
            sceneProjectCount = entries.filter {
                $0.classification != .notSceneProject && $0.classification != .projectManifestFailure
            }.count
            staticScriptSceneCount = entries.filter { $0.staticTransformScriptCount > 0 }.count
            staticTransformScriptCount = entries.reduce(0) { $0 + $1.staticTransformScriptCount }
            uniqueStaticTransformScriptSourceCount = entries.reduce(0) {
                $0 + $1.uniqueStaticTransformScriptSourceCount
            }
            classificationCounts = Dictionary(
                grouping: entries,
                by: { $0.classification.rawValue }
            ).mapValues(\.count)
        }
    }
}

private enum SceneScriptXPCCorpusRunClassification: String, Codable {
    case completed
    case corpusUnavailable
    case serviceUnavailable
}

private enum SceneScriptXPCCorpusClassification: String, Codable {
    case notSceneProject
    case projectManifestFailure
    case extractionFailure
    case parseFailure
    case noStaticTransformScripts
    case exact
    case mismatch

    var isFailure: Bool {
        switch self {
        case .projectManifestFailure, .extractionFailure, .parseFailure, .mismatch:
            true
        case .notSceneProject, .noStaticTransformScripts, .exact:
            false
        }
    }
}
#endif
