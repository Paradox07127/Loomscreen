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
        let serviceStart = try #require(project.range(
            of: "0C5C10000000000000000010 /* SceneScriptXPCService */ = {",
            range: liteStart.upperBound..<project.endIndex
        ))
        let liteTarget = project[liteStart.lowerBound..<serviceStart.lowerBound]
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

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
