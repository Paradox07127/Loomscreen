import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Wallpaper Engine web property bridge")
struct WallpaperEngineWebPropertyBridgeTests {
    @Test("Builds an applyUserProperties bootstrap from project.json defaults")
    func buildsBootstrapFromProjectDefaults() throws {
        let folder = try makeProjectFolder(manifest: """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "introanimation": { "type": "bool", "text": "Intro Animation", "value": true },
              "modelresolution": { "type": "combo", "text": "Model Resolution", "value": "8k" },
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20 }
            }
          }
        }
        """)

        let script = try #require(WallpaperEngineWebPropertyBridge.bootstrapScript(forFolder: folder))

        #expect(script.contains("wallpaperPropertyListener"))
        #expect(script.contains("applyUserProperties"))
        #expect(script.contains("\"introanimation\":{\"value\":true}"))
        #expect(script.contains("\"modelresolution\":{\"value\":\"8k\"}"))
        #expect(script.contains("\"bgmvolume\":{\"value\":20}"))
        #expect(!script.contains("Intro Animation"))
    }

    @Test("Returns nil when a folder has no Wallpaper Engine property defaults")
    func nilWithoutPropertyDefaults() throws {
        let folder = try makeProjectFolder(manifest: """
        {
          "file": "index.html",
          "type": "Web"
        }
        """)

        #expect(WallpaperEngineWebPropertyBridge.bootstrapScript(forFolder: folder) == nil)
    }

    @Test("Hot apply only sends Wallpaper Engine properties whose effective value changed")
    func hotApplyOnlySendsChangedProperties() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "dialogx": { "type": "slider", "text": "Dialog X", "value": 33, "min": 0, "max": 100, "step": 0.1 },
              "dialogy": { "type": "slider", "text": "Dialog Y", "value": 53, "min": 0, "max": 100, "step": 0.1 },
              "modelresolution": { "type": "combo", "text": "Model Resolution", "value": "8k" }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.applyScript(
            schema: schema,
            previousOverrides: ["dialogx": .number(33)],
            overrides: ["dialogx": .number(34)]
        ))

        #expect(script.contains("\"dialogx\":{\"value\":34}"))
        #expect(!script.contains("dialogy"))
        #expect(!script.contains("modelresolution"))
    }

    private func makeProjectFolder(manifest: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEWebPropertyBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.data(using: .utf8)?.write(to: folder.appendingPathComponent("project.json"))
        return folder
    }
}
