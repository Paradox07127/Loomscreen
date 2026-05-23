import Foundation
import Testing
import LiveWallpaperCore
@testable import LiveWallpaper

@Suite("Wallpaper Engine project custom properties")
struct WallpaperEngineProjectPropertiesTests {
    @Test("Parses localized web project properties in Wallpaper Engine order")
    func parsesLocalizedProjectProperties() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(sampleManifest.utf8),
            preferredLanguages: ["zh-Hans", "en-US"]
        )

        #expect(schema.hasMeaningfulSettings)
        #expect(schema.properties.map(\.key) == [
            "text_music",
            "music",
            "bgmvolume",
            "modelresolution",
            "customtext"
        ])

        let volume = try #require(schema.properties.first { $0.key == "bgmvolume" })
        #expect(volume.displayText == "音量")
        #expect(volume.type == .slider)
        #expect(volume.minimum == 0)
        #expect(volume.maximum == 100)
        #expect(volume.step == 1)
        #expect(volume.defaultValue == .number(20))

        let resolution = try #require(schema.properties.first { $0.key == "modelresolution" })
        #expect(resolution.type == .combo)
        #expect(resolution.options.map(\.displayLabel) == ["4K", "8K"])
        #expect(resolution.defaultValue == .string("8k"))
    }

    @Test("Evaluates common Wallpaper Engine display conditions against current values")
    func evaluatesDisplayConditions() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(sampleManifest.utf8),
            preferredLanguages: ["en-US"]
        )

        let defaultValues = schema.effectiveValues(overrides: [:])
        #expect(schema.visibleProperties(values: defaultValues).contains { $0.key == "bgmvolume" })

        let mutedValues = schema.effectiveValues(overrides: ["music": .bool(false)])
        #expect(!schema.visibleProperties(values: mutedValues).contains { $0.key == "bgmvolume" })
    }

    @Test("Evaluates Wallpaper Engine OR and includes display conditions")
    func evaluatesCompoundDisplayConditions() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(compoundConditionManifest.utf8),
            preferredLanguages: ["en-US"]
        )

        let defaultValues = schema.effectiveValues(overrides: [:])
        let defaultVisible = schema.visibleProperties(values: defaultValues).map(\.key)
        #expect(defaultVisible.contains("backgroundimage"))
        #expect(defaultVisible.contains("dockslot"))

        let hiddenValues = schema.effectiveValues(overrides: [
            "backgroundsource": .number(1),
            "slotcount": .number(1)
        ])
        let hiddenVisible = schema.visibleProperties(values: hiddenValues).map(\.key)
        #expect(!hiddenVisible.contains("backgroundimage"))
        #expect(!hiddenVisible.contains("dockslot"))
    }

    @Test("HTMLConfig persists Wallpaper Engine project property overrides")
    func htmlConfigPersistsProjectPropertyOverrides() throws {
        let config = HTMLConfig(
            physicalPixelLayout: true,
            wallpaperEngineProjectProperties: [
                "bgmvolume": .number(33),
                "mouseactions": .bool(true),
                "modelresolution": .string("4k")
            ]
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HTMLConfig.self, from: data)

        #expect(decoded.wallpaperEngineProjectProperties["bgmvolume"] == .number(33))
        #expect(decoded.wallpaperEngineProjectProperties["mouseactions"] == .bool(true))
        #expect(decoded.wallpaperEngineProjectProperties["modelresolution"] == .string("4k"))
        #expect(decoded.physicalPixelLayout)
    }

    @Test("Web property bridge uses user overrides over project defaults")
    func bridgeUsesOverridesOverDefaults() throws {
        let folder = try makeProjectFolder(manifest: sampleManifest)

        let script = try #require(WallpaperEngineWebPropertyBridge.bootstrapScript(
            forFolder: folder,
            overrides: [
                "bgmvolume": .number(33),
                "music": .bool(false),
                "modelresolution": .string("4k")
            ]
        ))

        #expect(script.contains("\"bgmvolume\":{\"value\":33}"))
        #expect(script.contains("\"music\":{\"value\":false}"))
        #expect(script.contains("\"modelresolution\":{\"value\":\"4k\"}"))
        #expect(!script.contains("\"schemecolor\""))
    }

    @Test("Inspector schema loader accepts WPE web folders even when origin metadata is absent")
    func inspectorSchemaLoaderAcceptsFolderWithoutOrigin() async throws {
        let folder = try makeProjectFolder(manifest: sampleManifest)
        let bookmark = try folder.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let outcome = await WPEProjectCustomSettingsSchemaLoader.load(
            source: .folder(bookmarkData: bookmark, indexFileName: "index.html"),
            wpeOrigin: nil
        )

        let schema = try #require(outcome.schema)
        #expect(schema.hasMeaningfulSettings)
        #expect(schema.properties.contains { $0.key == "bgmvolume" })
    }

    private var sampleManifest: String {
        """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "localization": {
              "en-us": {
                "ui_music": "Music",
                "ui_volume": "Volume",
                "ui_custom_text": "Custom Text"
              },
              "zh-chs": {
                "ui_music": "背景音乐",
                "ui_volume": "音量",
                "ui_custom_text": "自定义文字"
              }
            },
            "properties": {
              "schemecolor": { "type": "color", "text": "ui_browse_properties_scheme_color", "value": "1 1 1", "order": 0 },
              "text_music": { "type": "text", "text": "<h4>ui_music</h4>", "order": 100, "index": 0 },
              "music": { "type": "bool", "text": "ui_music", "value": true, "order": 101, "index": 1 },
              "bgmvolume": { "type": "slider", "text": "ui_volume", "value": 20, "min": 0, "max": 100, "step": 1, "condition": "music.value == true", "order": 102, "index": 2 },
              "modelresolution": {
                "type": "combo",
                "text": "Model Resolution",
                "value": "8k",
                "order": 103,
                "index": 3,
                "options": [
                  { "label": "4K", "value": "4k" },
                  { "label": "8K", "value": "8k" }
                ]
              },
              "customtext": { "type": "textinput", "text": "ui_custom_text", "value": "Hello", "order": 104, "index": 4 }
            }
          }
        }
        """
    }

    private var compoundConditionManifest: String {
        """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "backgroundsource": { "type": "slider", "text": "Background Source", "value": 2, "min": 0, "max": 4, "order": 100 },
              "backgroundimage": { "type": "file", "text": "Background Image", "value": "", "condition": "backgroundsource.value == 2 || backgroundsource.value == 3", "order": 101 },
              "slotcount": { "type": "slider", "text": "Slot Count", "value": 2, "min": 1, "max": 5, "order": 102 },
              "dockslot": { "type": "bool", "text": "Dock Slot", "value": true, "condition": "[2, 3, 4].includes(slotcount.value)", "order": 103 }
            }
          }
        }
        """
    }

    private func makeProjectFolder(manifest: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEProjectPropertiesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }
}
