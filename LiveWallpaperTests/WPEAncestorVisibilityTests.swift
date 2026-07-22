import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

struct WPEAncestorVisibilityTests {
    @Test("Parser exposes parent + own-visibility for groups and layers")
    func parserExposesHierarchy() throws {
        let json: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [
                ["id": 1, "name": "group", "visible": ["user": "feat", "value": false]],
                ["id": 2, "name": "child", "parent": 1, "image": "models/util/solidlayer.json",
                 "visible": ["script": "export function update(){}", "value": true]],
                ["id": 3, "name": "top", "image": "models/util/solidlayer.json",
                 "visible": ["script": "export function update(){}", "value": true]],
            ],
        ]
        let doc = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json))
        #expect(doc.objectParentByID["2"] == "1")
        #expect(doc.objectParentByID["3"] == nil)
        #expect(doc.ownVisibilityByID["1"] == false)
        #expect(doc.ownVisibilityByID["2"] == true)
    }

    @Test("Live ancestor chain: hidden group hides child; live toggle re-shows it")
    func liveChainFold() {
        let parents = ["2": "1", "3": "1", "top": "none-existent-skip"]
        let own = ["1": false, "2": true, "3": true]

        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "2", parentByID: parents, liveLayerVisibility: [:], liveTextVisibility: [:], ownVisibilityByID: own) == false)

        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "2", parentByID: parents, liveLayerVisibility: ["1": true], liveTextVisibility: [:], ownVisibilityByID: own) == true)

        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "nochild", parentByID: parents, liveLayerVisibility: [:], liveTextVisibility: [:], ownVisibilityByID: own) == true)
    }

    @Test("Live ancestor chain: cycle-safe")
    func chainCycleSafe() {
        let parents = ["a": "b", "b": "a"]
        #expect(WPEMetalSceneRenderer.ancestorChainVisible(
            "a", parentByID: parents, liveLayerVisibility: [:], liveTextVisibility: [:], ownVisibilityByID: ["a": true, "b": true]) == true)
    }
}
