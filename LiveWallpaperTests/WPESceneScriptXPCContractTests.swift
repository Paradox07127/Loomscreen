import Foundation
@testable import LiveWallpaper
import Testing

@Suite(.serialized)
struct WPESceneScriptXPCContractTests {
    @Test("Wire codec preserves typed pure-data batches")
    func wireCodecRoundTrip() throws {
        let request = SceneScriptXPCStaticTransformRequest(
            protocolVersion: SceneScriptXPCServiceIdentity.protocolVersion,
            requestID: UUID(),
            deadlineMilliseconds: 500,
            canvasWidth: 3_840,
            canvasHeight: 2_160,
            items: [
                .init(
                    script: "export function update(value) { return value; }",
                    properties: [
                        "number": .number(0.5),
                        "bool": .bool(true),
                        "string": .string("safe")
                    ],
                    seed: .init(x: 1, y: 2, z: 3)
                )
            ]
        )

        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(
            SceneScriptXPCStaticTransformRequest.self,
            from: data
        ) == request)
    }

    @Test("Project embeds one Pro-only service and grants it only App Sandbox")
    func projectAndEntitlementBoundary() throws {
        let project = try Self.read("LiveWallpaper.xcodeproj/project.pbxproj")
        #expect(project.contains("productType = \"com.apple.product-type.xpc-service\";"))
        #expect(project.contains("$(CONTENTS_FOLDER_PATH)/XPCServices"))
        #expect(project.contains("0C5C10000000000000000015 /* PBXTargetDependency */"))

        let liteStart = try #require(project.range(
            of: "0CA00000000000000000B001 /* LiveWallpaperLite */ = {"
        ))
        let liteEnd = try #require(project.range(
            of: "\n\t\t};",
            range: liteStart.upperBound..<project.endIndex
        ))
        let liteTarget = project[liteStart.lowerBound..<liteEnd.upperBound]
        #expect(!liteTarget.contains("SceneScriptXPC"))

        let entitlementURL = Self.repositoryRoot
            .appendingPathComponent("SceneScriptXPCService/SceneScriptXPCService.entitlements")
        let data = try Data(contentsOf: entitlementURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist.count == 1)
        #expect(plist["com.apple.security.app-sandbox"] as? Bool == true)
    }

    @Test("Protocol surface contains no renderer, media, file, or bookmark object")
    func protocolIsPureData() throws {
        let source = try Self.read("SceneScriptXPCShared/SceneScriptXPCProtocol.swift")
        #expect(source.contains("func evaluateStaticTransforms("))
        #expect(source.contains("_ requestData: Data"))
        for forbidden in ["JSValue", "MTL", "AVPlayer", "URL", "Bookmark", "NSFileHandle"] {
            #expect(!source.contains(forbidden))
        }
    }

    @Test("SceneScript uses one process worker with serialized bounded evaluation")
    func processWorkerIsSerializedAndBounded() throws {
        let client = try Self.read("LiveWallpaper/Runtime/Scene/WPESceneScriptXPCClient.swift")
        let service = try Self.read("SceneScriptXPCService/SceneScriptXPCService.swift")

        #expect(client.contains("private static let processGate = NSLock()"))
        #expect(service.contains("private let worker = SceneScriptXPCWorker()"))
        #expect(service.contains("private let evaluationLock = NSLock()"))
        #expect(service.contains("evaluationLock.lock()"))
        #expect(service.contains("defer { evaluationLock.unlock() }"))

        for limit in [
            "maximumRequestBytes",
            "maximumBatchItems",
            "maximumUniqueSources",
            "maximumScriptBytes",
            "maximumTotalScriptBytes",
            "maximumPropertiesPerItem",
            "maximumPropertyKeyBytes",
            "maximumPropertyStringBytes",
            "maximumDeadlineMilliseconds",
            "maximumCanvasDimension",
        ] {
            #expect(service.contains("static let \(limit)"), "Missing service limit: \(limit)")
        }

        for forbiddenPoolShape in [
            "workersByScene",
            "workerByScene",
            "SceneScriptWorkerPool",
            "[SceneScriptXPCWorker]",
        ] {
            #expect(!service.contains(forbiddenPoolShape))
            #expect(!client.contains(forbiddenPoolShape))
        }
    }

    @Test("Transport recovery admits one XPC attempt after a process-wide cooldown")
    func transportRecoveryIsCooldownGatedAndSingleAttempt() throws {
        let source = try Self.read("LiveWallpaper/Runtime/Scene/WPESceneScriptXPCClient.swift")
        let processGate = try #require(source.range(of: "Self.processGate.lock()"))
        let circuitGate = try #require(source.range(
            of: "guard Self.recoveryCircuit.allowsAttempt else"
        ))
        let connection = try #require(source.range(
            of: "let connection = NSXPCConnection("
        ))

        #expect(processGate.lowerBound < circuitGate.lowerBound)
        #expect(circuitGate.lowerBound < connection.lowerBound)
        #expect(source.contains("XPCRecoveryCircuit(cooldownSeconds: 10.5)"))
        #expect(Self.occurrenceCount("let connection = NSXPCConnection(", in: source) == 1)
        #expect(Self.occurrenceCount("proxy.evaluateStaticTransforms(", in: source) == 1)
        #expect(Self.occurrenceCount("Self.recoveryCircuit.recordTransportFailure()", in: source) >= 3)
        #expect(source.contains("Self.recoveryCircuit.recordHealthyReply()"))
    }

    @Test("Shipping host never falls back to in-process JavaScript")
    func shippingHostFailsClosedWithoutHelper() {
        #expect(
            WPETransformScriptEvaluator.executionRoute(
                embeddedServiceAvailable: false,
                hostIsApplicationBundle: true
            ) == .keepBakedFailClosed
        )
        #expect(
            WPETransformScriptEvaluator.executionRoute(
                embeddedServiceAvailable: true,
                hostIsApplicationBundle: true
            ) == .helperService
        )
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func occurrenceCount(_ needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
