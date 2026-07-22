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
        defer { try? FileManager.default.removeItem(at: folder) }

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
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(WallpaperEngineWebPropertyBridge.bootstrapScript(forFolder: folder) == nil)
    }

    @Test("Bootstrap script installs a defineProperty hook on wallpaperPropertyListener")
    func bootstrapInstallsDefinePropertyHook() throws {
        let folder = try makeProjectFolder(manifest: """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "color": { "type": "color", "text": "Color", "value": "1 0 0" }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: folder) }

        let script = try #require(WallpaperEngineWebPropertyBridge.bootstrapScript(forFolder: folder))

        #expect(script.contains("Object.defineProperty(window, 'wallpaperPropertyListener'"))
        #expect(script.contains("set:"))
        #expect(script.contains("requestAnimationFrame"))
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

    @Test("Master audio maps to Wallpaper Engine volume sliders at runtime")
    func masterAudioMapsToWallpaperEngineVolumeSliders() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "music": { "type": "bool", "text": "Music", "value": true },
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20, "min": 0, "max": 100, "step": 1 },
              "dialogx": { "type": "slider", "text": "Dialog X", "value": 33, "min": 0, "max": 100 }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.audioControlScript(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 0.35,
            muted: false
        ))

        #expect(script.contains("applyUserProperties"))
        #expect(script.contains("\"bgmvolume\":{\"value\":28}"))
        #expect(!script.contains("\"music\""))
        #expect(!script.contains("\"dialogx\""))
    }

    @Test("Master audio restores project volume when returning to full volume")
    func masterAudioRestoresProjectVolumeAtFullVolume() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20, "min": 0, "max": 100, "step": 1 }
            }
          }
        }
        """.utf8))

        let script = try #require(WallpaperEngineWebPropertyBridge.audioControlScript(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 1,
            muted: false
        ))

        #expect(script.contains("\"bgmvolume\":{\"value\":80}"))
    }

    @Test("Bootstrap audio overrides only when master audio is active")
    func bootstrapAudioOverridesOnlyWhenMasterAudioIsActive() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(data: Data("""
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "bgmvolume": { "type": "slider", "text": "BGM Volume", "value": 20, "min": 0, "max": 100, "step": 1 }
            }
          }
        }
        """.utf8))

        #expect(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 1,
            muted: false
        ).isEmpty)

        #expect(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
            schema: schema,
            projectOverrides: ["bgmvolume": .number(80)],
            volume: 0.35,
            muted: false
        )["bgmvolume"] == .number(28))

        #expect(WallpaperEngineWebPropertyBridge.audioBootstrapOverrides(
            schema: schema,
            projectOverrides: [:],
            volume: 0.35,
            muted: false
        )["bgmvolume"] == .number(7))
    }

    private func makeProjectFolder(manifest: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEWebPropertyBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.data(using: .utf8)?.write(to: folder.appendingPathComponent("project.json"))
        return folder
    }
}
