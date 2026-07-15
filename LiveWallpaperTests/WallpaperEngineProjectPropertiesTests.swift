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

    @Test("Resolves raw WPE keys and identifiers to readable labels; keeps author text")
    func resolvesDisplayKeysAndIdentifiers() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(displayNameResolutionManifest.utf8),
            preferredLanguages: ["en-US"]
        )
        let labels = Dictionary(uniqueKeysWithValues: schema.properties.map { ($0.key, $0.displayText) })
        // Known WPE key + `ui_browse_properties_*` prefix + snake_case all resolve.
        #expect(labels["pknown"] == "Scheme Color")
        #expect(labels["psnake"] == "Particle Density")
        #expect(labels["pbrowse"] == "Bloom Strength")
        // Conservative: camelCase and author plain text pass through verbatim.
        #expect(labels["pcamel"] == "modelResolution")
        #expect(labels["pauthor"] == "Artist Label: Keep as Written")
        // The raw key must never survive to the UI.
        #expect(schema.properties.allSatisfy { !$0.displayText.hasPrefix("ui_browse_properties_") })
        #expect(schema.properties.allSatisfy { !$0.displayText.contains("_") })
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

    @Test("Flags embedded ad/donation/link properties, keeps real settings")
    func detectsPromotionalLinkProperties() throws {
        let manifest = """
        {
          "general": {
            "properties": {
              "windspeed": { "type": "slider", "text": "Wind Speed", "value": 5, "min": 0, "max": 10 },
              "clock": { "type": "combo", "text": "<h2>🕑Clock type<h2>", "value": "1", "options": [{"label":"Digital","value":"1"}] },
              "schemecolor": { "type": "color", "text": "ui_browse_properties_scheme_color", "value": "1 1 1" },
              "koflink": { "type": "bool", "text": "<a href='https://ko-fi.com/abc'>Support me</a>", "value": true },
              "qr": { "type": "color", "text": "<img src='http://qq.com/x.png'>", "value": "1 1 1" },
              "bbyy": { "type": "bool", "text": "显示赞助信息 Display sponsorship", "value": false },
              "ahrefhttpskoficomabcdefghijklmnopqrstuvwxyz": { "type": "bool", "text": "buy me a coffee", "value": true },
              "enableparallaxdepthoffieldforbackgroundlayers": { "type": "bool", "text": "Real Setting", "value": true },
              "bgsource": { "type": "combo", "text": "Background Source", "value": "a", "options": [{"label":"Default","value":"https://example.com/default.jpg"}] },
              "sociallinks": { "type": "combo", "text": "Links", "value": "1", "options": [{"label":"<a href='https://x.com'>Follow</a>","value":"1"}] }
            }
          }
        }
        """
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(manifest.utf8),
            preferredLanguages: ["en-US"],
            includeSchemeColor: true
        )
        let promo = Dictionary(uniqueKeysWithValues: schema.properties.map { ($0.key, $0.isPromotionalLink) })

        // Real, render-affecting settings — keep, even with cosmetic <h2> markup.
        #expect(promo["windspeed"] == false)
        #expect(promo["clock"] == false)
        #expect(promo["schemecolor"] == false)
        // A descriptive long key with no promo token must NOT be hidden.
        #expect(promo["enableparallaxdepthoffieldforbackgroundlayers"] == false)
        // A combo whose option *value* is URL-like but label is clean — keep.
        #expect(promo["bgsource"] == false)

        // Ads / donations / external links — hide.
        #expect(promo["koflink"] == true)
        #expect(promo["qr"] == true)
        #expect(promo["bbyy"] == true)
        #expect(promo["ahrefhttpskoficomabcdefghijklmnopqrstuvwxyz"] == true)
        #expect(promo["sociallinks"] == true)
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

    @Test("HTMLConfig stores Wallpaper Engine overrides by project key")
    func htmlConfigStoresProjectPropertyOverridesByProjectKey() throws {
        var config = HTMLConfig(
            wallpaperEngineProjectProperties: [
                "bgmvolume": .number(20)
            ]
        )

        #expect(config.projectWallpaperEngineProperties(forProjectKey: "project-a")["bgmvolume"] == .number(20))

        config.setWallpaperEngineProjectProperties(
            [
                "bgmvolume": .number(33),
                "modelresolution": .string("4k")
            ],
            forProjectKey: "project-a"
        )
        config.setWallpaperEngineProjectProperties(
            [
                "bgmvolume": .number(12)
            ],
            forProjectKey: "project-b"
        )

        #expect(config.wallpaperEngineProjectProperties.isEmpty)
        #expect(config.projectWallpaperEngineProperties(forProjectKey: "project-a")["bgmvolume"] == .number(33))
        #expect(config.projectWallpaperEngineProperties(forProjectKey: "project-a")["modelresolution"] == .string("4k"))
        #expect(config.projectWallpaperEngineProperties(forProjectKey: "project-b")["bgmvolume"] == .number(12))

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HTMLConfig.self, from: data)

        #expect(decoded.wallpaperEngineProjectProperties.isEmpty)
        #expect(decoded.projectWallpaperEngineProperties(forProjectKey: "project-a")["bgmvolume"] == .number(33))
        #expect(decoded.projectWallpaperEngineProperties(forProjectKey: "project-b")["bgmvolume"] == .number(12))
    }

    @Test("Wallpaper Engine project identity keys are stable per HTML folder source")
    func projectIdentityKeysAreStablePerHTMLFolderSource() throws {
        let sourceA = HTMLSource.folder(bookmarkData: Data([0x01, 0x02, 0x03]), indexFileName: "index.html")
        let sourceARepeat = HTMLSource.folder(bookmarkData: Data([0x01, 0x02, 0x03]), indexFileName: "index.html")
        let sourceB = HTMLSource.folder(bookmarkData: Data([0x04, 0x05, 0x06]), indexFileName: "index.html")

        let keyA = try #require(WallpaperEngineProjectIdentity.key(source: sourceA))
        let keyARepeat = try #require(WallpaperEngineProjectIdentity.key(source: sourceARepeat))
        let keyB = try #require(WallpaperEngineProjectIdentity.key(source: sourceB))

        #expect(keyA == keyARepeat)
        #expect(keyA != keyB)
        #expect(WallpaperEngineProjectIdentity.key(source: .url(URL(string: "https://example.com")!)) == nil)
    }

    @Test("Web property bridge uses user overrides over project defaults")
    func bridgeUsesOverridesOverDefaults() throws {
        let folder = try makeProjectFolder(manifest: sampleManifest)
        defer { try? FileManager.default.removeItem(at: folder) }

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
        defer { try? FileManager.default.removeItem(at: folder) }
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

    @Test("Project property schema cache invalidates when project.json changes")
    func schemaCacheInvalidatesWhenManifestChanges() throws {
        let folder = try makeProjectFolder(manifest: manifestWithProperty(key: "speed", text: "Speed"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = WallpaperEngineProjectPropertySchemaCache(limit: 8)

        let first = try cache.schema(from: folder, preferredLanguages: ["en-US"])
        #expect(first.properties.map(\.key) == ["speed"])

        let manifestURL = folder.appendingPathComponent("project.json")
        try Data(manifestWithProperty(key: "density", text: "Density").utf8).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)],
            ofItemAtPath: manifestURL.path
        )

        let second = try cache.schema(from: folder, preferredLanguages: ["en-US"])
        #expect(second.properties.map(\.key) == ["density"])
    }

    @Test("Project property schema cache separates schemecolor inclusion")
    func schemaCacheSeparatesSchemeColorInclusion() throws {
        let folder = try makeProjectFolder(manifest: sampleManifest)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = WallpaperEngineProjectPropertySchemaCache(limit: 8)

        let hidden = try cache.schema(from: folder, preferredLanguages: ["en-US"], includeSchemeColor: false)
        let visible = try cache.schema(from: folder, preferredLanguages: ["en-US"], includeSchemeColor: true)

        #expect(!hidden.properties.contains { $0.key == "schemecolor" })
        #expect(visible.properties.contains { $0.key == "schemecolor" })
    }

    @Test("Scene settings presentation groups visible controls by project group and skips scheme color")
    func sceneSettingsPresentationGroupsControlsAndSkipsSchemeColor() throws {
        let manifest = """
        {
          "general": {
            "properties": {
              "schemecolor": { "type": "color", "text": "ui_browse_properties_scheme_color", "value": "1 1 1", "order": 1 },
              "mainGroup": { "type": "group", "text": "Main Settings", "order": 2 },
              "enabled": { "type": "bool", "text": "Enabled", "value": true, "order": 3 },
              "volume": { "type": "slider", "text": "Volume", "value": 20, "min": 0, "max": 100, "condition": "enabled", "order": 4 },
              "hiddenVolume": { "type": "slider", "text": "Hidden Volume", "value": 10, "min": 0, "max": 100, "condition": "!enabled", "order": 5 },
              "dockGroup": { "type": "group", "text": "Dock Settings", "order": 6 },
              "dockEnabled": { "type": "bool", "text": "Dock Enabled", "value": false, "order": 7 },
              "dockSize": { "type": "slider", "text": "Dock Size", "value": 1, "min": 0, "max": 2, "condition": "dockEnabled.value == true", "order": 8 },
              "support": { "type": "bool", "text": "<a href='https://ko-fi.com/example'>Support</a>", "value": true, "order": 9 }
            }
          }
        }
        """
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(manifest.utf8),
            preferredLanguages: ["en-US"],
            includeSchemeColor: true
        )

        let presentation = WPEProjectSettingsPresentation(
            schema: schema,
            overrides: [:],
            excludedKeys: ["schemecolor"]
        )

        #expect(presentation.sections.map(\.title) == ["Main Settings", "Dock Settings"])
        #expect(presentation.sections[0].properties.map(\.key) == ["enabled", "volume"])
        #expect(presentation.sections[1].properties.map(\.key) == ["dockEnabled"])
        #expect(!presentation.visibleKeys.contains("schemecolor"))
        #expect(!presentation.visibleKeys.contains("support"))
        #expect(!presentation.hasVisibleOverrides)
    }

    @Test("Scene settings presentation recomputes section children from overrides")
    func sceneSettingsPresentationRecomputesSectionsFromOverrides() throws {
        let manifest = """
        {
          "general": {
            "properties": {
              "dockGroup": { "type": "group", "text": "Dock Settings", "order": 1 },
              "dockEnabled": { "type": "bool", "text": "Dock Enabled", "value": false, "order": 2 },
              "dockSize": { "type": "slider", "text": "Dock Size", "value": 1, "min": 0, "max": 2, "condition": "dockEnabled.value == true", "order": 3 }
            }
          }
        }
        """
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(manifest.utf8),
            preferredLanguages: ["en-US"]
        )

        let presentation = WPEProjectSettingsPresentation(
            schema: schema,
            overrides: ["dockEnabled": .bool(true)],
            excludedKeys: ["schemecolor"]
        )

        #expect(presentation.sections.count == 1)
        #expect(presentation.sections[0].properties.map(\.key) == ["dockEnabled", "dockSize"])
        #expect(presentation.hasVisibleOverrides)
    }

    @Test("Scene settings presentation hides a conditioned group without dropping ungrouped controls")
    func sceneSettingsPresentationHidesConditionedGroupWithoutDroppingUngroupedControls() throws {
        let manifest = """
        {
          "general": {
            "properties": {
              "advanced": { "type": "bool", "text": "Advanced", "value": false, "order": 1 },
              "advancedGroup": { "type": "group", "text": "Advanced Settings", "condition": "advanced.value == true", "order": 2 },
              "advancedSize": { "type": "slider", "text": "Advanced Size", "value": 1, "min": 0, "max": 2, "order": 3 }
            }
          }
        }
        """
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(manifest.utf8),
            preferredLanguages: ["en-US"]
        )

        let hidden = WPEProjectSettingsPresentation(
            schema: schema,
            overrides: [:],
            excludedKeys: ["schemecolor"]
        )
        let visible = WPEProjectSettingsPresentation(
            schema: schema,
            overrides: ["advanced": .bool(true)],
            excludedKeys: ["schemecolor"]
        )

        #expect(hidden.sections.map(\.title) == ["Settings"])
        #expect(hidden.sections[0].properties.map(\.key) == ["advanced"])
        #expect(visible.sections.map(\.title) == ["Settings", "Advanced Settings"])
        #expect(visible.sections[1].properties.map(\.key) == ["advancedSize"])
    }

    @Test("Scene settings presentation starts with all sections collapsed")
    func sceneSettingsPresentationStartsWithAllSectionsCollapsed() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(groupedSceneSettingsManifest(propertyCount: 2).utf8),
            preferredLanguages: ["en-US"]
        )
        let presentation = WPEProjectSettingsPresentation(schema: schema, overrides: [:])

        #expect(!presentation.sections.isEmpty)
        // With no section pre-expanded, only the section headers render.
        #expect(presentation.rows(expandedSectionIDs: []).allSatisfy { row in
            if case .sectionHeader = row { return true }
            return false
        })
    }

    @Test("Scene settings presentation flattens expanded sections into all stable rows")
    func sceneSettingsPresentationFlattensExpandedSectionsIntoAllRows() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(groupedSceneSettingsManifest(propertyCount: 5).utf8),
            preferredLanguages: ["en-US"]
        )
        let presentation = WPEProjectSettingsPresentation(schema: schema, overrides: [:])

        let collapsedRows = presentation.rows(expandedSectionIDs: [])
        let expandedRows = presentation.rows(expandedSectionIDs: ["mainGroup"])

        #expect(collapsedRows.map(\.id) == ["section:mainGroup"])
        #expect(expandedRows.map(\.id) == [
            "section:mainGroup",
            "property:setting1",
            "property:setting2",
            "property:setting3",
            "property:setting4",
            "property:setting5"
        ])
    }

    @Test("Scene settings presentation includes every property in expanded large sections")
    func sceneSettingsPresentationIncludesEveryPropertyInExpandedLargeSections() throws {
        let schema = try WallpaperEngineProjectPropertySchema.parse(
            data: Data(groupedSceneSettingsManifest(propertyCount: 12).utf8),
            preferredLanguages: ["en-US"]
        )
        let presentation = WPEProjectSettingsPresentation(schema: schema, overrides: [:])
        let rows = presentation.rows(expandedSectionIDs: ["mainGroup"])

        #expect(rows.count == 13)
        #expect(rows.first?.id == "section:mainGroup")
        #expect(rows.last?.id == "property:setting12")
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

    private var displayNameResolutionManifest: String {
        """
        {
          "file": "index.html",
          "type": "Web",
          "general": {
            "properties": {
              "pknown":  { "type": "slider", "text": "ui_browse_properties_scheme_color", "value": 1, "min": 0, "max": 1, "order": 0 },
              "psnake":  { "type": "slider", "text": "particle_density", "value": 1, "min": 0, "max": 1, "order": 1 },
              "pbrowse": { "type": "slider", "text": "ui_browse_properties_bloom_strength", "value": 1, "min": 0, "max": 1, "order": 2 },
              "pcamel":  { "type": "combo", "text": "modelResolution", "value": "4k", "order": 3, "options": [ { "label": "4K", "value": "4k" } ] },
              "pauthor": { "type": "textinput", "text": "Artist Label: Keep as Written", "value": "", "order": 4 }
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

    private func manifestWithProperty(key: String, text: String) -> String {
        """
        {
          "file": "scene.json",
          "type": "Scene",
          "general": {
            "properties": {
              "\(key)": { "type": "slider", "text": "\(text)", "value": 1, "min": 0, "max": 10, "order": 1 }
            }
          }
        }
        """
    }

    private func groupedSceneSettingsManifest(propertyCount: Int) -> String {
        let settings = (1...propertyCount).map { index in
            """
              "setting\(index)": { "type": "bool", "text": "Setting \(index)", "value": false, "order": \(index + 1) }
            """
        }.joined(separator: ",\n")

        return """
        {
          "file": "scene.json",
          "type": "Scene",
          "general": {
            "properties": {
              "mainGroup": { "type": "group", "text": "Main Settings", "order": 1 },
        \(settings)
            }
          }
        }
        """
    }
}
