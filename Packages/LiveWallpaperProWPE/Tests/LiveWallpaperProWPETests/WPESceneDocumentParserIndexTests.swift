import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaperProWPE

/// Locks the single-canonical-index behavior shared by the transform, visibility,
/// hierarchy and attachment passes: duplicate object ids resolve last-write-wins
/// across every field, and a deeply nested group's attachment is inherited by a
/// descendant image through the memoized ancestor walk.
@Suite("WPESceneDocumentParser object index")
struct WPESceneDocumentParserIndexTests {

    /// The parser cannot depend on the JS script runtime, so tests supply a no-op
    /// resolver — none of these fixtures use origin scripts.
    private struct NoScriptResolver: WPESceneTransformScriptResolving {
        func resolveVec3(
            script: String,
            properties: [String: WPESceneScriptPropertyValue],
            seed: SIMD3<Double>
        ) -> SIMD3<Double>? { nil }
    }

    private func parse(_ payload: [String: Any]) throws -> WPESceneDocument {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try WPESceneDocumentParser.parse(
            data: data,
            userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScriptResolver() }
        )
    }

    @Test("Duplicate object ids resolve last-write-wins for transform, visibility and parent")
    func duplicateObjectIDResolvesLastWins() throws {
        // Two image objects share id 100 (a malformed export / corrupt .pkg). Every
        // pass must resolve the SAME source object — the last one — instead of
        // transform reading the first while hierarchy/visibility read the last.
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                [
                    "id": 100,
                    "name": "first",
                    "image": "models/first.json",
                    "origin": "111 0 0",
                    "visible": true,
                    "parent": 10,
                ],
                [
                    "id": 100,
                    "name": "second",
                    "image": "models/second.json",
                    "origin": "222 0 0",
                    "visible": false,
                    "parent": 20,
                ],
            ],
        ]
        let document = try parse(payload)

        // Every parsed image object keyed to id 100 shares the last-wins transform
        // and visibility (the parser emits one image per raw entry).
        let duplicates = document.imageObjects.filter { $0.id == "100" }
        #expect(!duplicates.isEmpty)
        for object in duplicates {
            #expect(abs(object.origin.x - 222) < 0.001)
            #expect(object.visible == false)
        }
        // Hierarchy resolves the last duplicate's parent too.
        #expect(document.objectParentByID["100"] == "20")
    }

    @Test("A nested group's attachment is inherited by a deep descendant image")
    func nestedGroupAttachmentInheritedByDeepChild() throws {
        // body(10) → groupA(20, attachment 头部) → groupB(30, no attachment) →
        // image(40). The child walks past the attachment-less nearer group to the
        // first group carrying an anchor, inheriting its name and the group's parent.
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
            "objects": [
                ["id": 10, "name": "body", "image": "models/body.json", "origin": "0 0 0"],
                ["id": 20, "name": "groupA", "attachment": "头部", "parent": 10],
                ["id": 30, "name": "groupB", "parent": 20],
                ["id": 40, "name": "hair", "image": "models/hair.json", "parent": 30],
            ],
        ]
        let document = try parse(payload)
        let child = try #require(document.imageObjects.first { $0.id == "40" })
        #expect(child.attachment == "头部")
        #expect(child.parentObjectID == "10")
    }
}
