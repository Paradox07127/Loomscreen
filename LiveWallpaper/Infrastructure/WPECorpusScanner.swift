#if !LITE_BUILD
import Foundation

/// Read-only inventory of a Wallpaper Engine corpus directory (e.g. a Steam
/// Workshop sync folder). Drives the regression gate: every later phase is
/// validated by re-scanning the corpus and asserting the report matches the
/// expected feature counts. The scanner never extracts a full `scene.pkg` —
/// it streams the package index and reads only the JSON entries it needs to
/// classify object kinds and shader names.
struct WPECorpusScanner {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func scan() async throws -> WPECorpusReport {
        let projectURLs = try Self.enumerateProjectFolders(under: rootURL)
        var builder = ReportBuilder()

        for url in projectURLs.sorted(by: { $0.path < $1.path }) {
            do {
                try ingestProject(at: url, into: &builder)
            } catch {
                builder.note(scanError: error, at: url)
            }
        }

        return builder.finish()
    }

    private static func enumerateProjectFolders(under root: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func ingestProject(at folderURL: URL, into builder: inout ReportBuilder) throws {
        let project: WallpaperEngineProject
        do {
            project = try WallpaperEngineProject.read(from: folderURL)
        } catch {
            builder.note(missingProjectJSON: folderURL.lastPathComponent)
            return
        }

        builder.note(projectType: project.type)

        guard project.type == .scene else { return }

        let pkgURL = folderURL.appendingPathComponent("scene.pkg")
        if FileManager.default.fileExists(atPath: pkgURL.path) {
            builder.note(scenePackagePresent: true)
            try ingestScenePackage(at: pkgURL, project: project, into: &builder)
        } else {
            builder.note(scenePackagePresent: false)
            try ingestUnpackedScene(at: folderURL, project: project, into: &builder)
        }
    }

    private func ingestScenePackage(
        at pkgURL: URL,
        project: WallpaperEngineProject,
        into builder: inout ReportBuilder
    ) throws {
        let handle = try FileHandle(forReadingFrom: pkgURL)
        defer { try? handle.close() }

        let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)

        for entry in package.entries {
            builder.note(entry: entry.name)
        }
        builder.note(shaderSourcesPresent: package.entries.contains { entry in
            let lowered = entry.name.lowercased()
            return lowered.hasSuffix(".vert") || lowered.hasSuffix(".frag")
        })

        let entryFile = project.entryFile.isEmpty ? "scene.json" : project.entryFile
        guard let sceneEntry = package.entry(named: entryFile)
            ?? package.entry(named: "scene.json") else {
            builder.note(sceneJSONMissing: pkgURL.deletingLastPathComponent().lastPathComponent)
            return
        }

        let sceneData = try package.readEntry(sceneEntry, from: handle)
        ingestSceneJSON(sceneData, into: &builder)
        try ingestMaterialsAndEffects(in: package, handle: handle, into: &builder)
    }

    private func ingestUnpackedScene(
        at folderURL: URL,
        project: WallpaperEngineProject,
        into builder: inout ReportBuilder
    ) throws {
        let entryURL = folderURL.appendingPathComponent(project.entryFile.isEmpty ? "scene.json" : project.entryFile)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            builder.note(sceneJSONMissing: folderURL.lastPathComponent)
            return
        }

        var materialPayloads: [Data] = []
        if let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            var sawShader = false
            for case let url as URL in enumerator {
                let relative = url.path.dropFirst(folderURL.path.count + 1)
                builder.note(entry: String(relative))
                let lowered = url.pathExtension.lowercased()
                if lowered == "vert" || lowered == "frag" { sawShader = true }
                if lowered == "json" {
                    let folderName = url.deletingLastPathComponent().lastPathComponent.lowercased()
                    if folderName == "materials" || folderName == "effects"
                        || url.deletingLastPathComponent().path.contains("/effects/") {
                        if let payload = try? Data(contentsOf: url) {
                            materialPayloads.append(payload)
                        }
                    }
                }
            }
            builder.note(shaderSourcesPresent: sawShader)
        }

        let data = try Data(contentsOf: entryURL)
        ingestSceneJSON(data, into: &builder)
        for payload in materialPayloads {
            ingestMaterialOrEffect(data: payload, into: &builder)
        }
    }

    private func ingestSceneJSON(_ data: Data, into builder: inout ReportBuilder) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any] else {
            builder.note(malformedSceneJSON: true)
            return
        }
        let objects = (json["objects"] as? [[String: Any]]) ?? []
        var sceneFlags = WPESceneFeatureSet()
        for obj in objects {
            let kind = Self.classifyObject(obj)
            builder.note(objectKind: kind)
            switch kind {
            case .particle: sceneFlags.insert(.particleObject)
            case .text:     sceneFlags.insert(.textObject)
            case .sound:    sceneFlags.insert(.soundObject)
            case .light:    sceneFlags.insert(.lightObject)
            case .unknown:  sceneFlags.insert(.unknownObject)
            case .image:    break
            }
            if let layers = obj["animationlayers"] as? [Any], !layers.isEmpty {
                sceneFlags.insert(.animationLayer)
            }
            if let effects = obj["effects"] as? [Any], !effects.isEmpty {
                sceneFlags.insert(.imageEffect)
            }
        }
        builder.note(sceneFeatureSet: sceneFlags)
    }

    private func ingestMaterialsAndEffects(
        in package: WallpaperEnginePackage,
        handle: FileHandle,
        into builder: inout ReportBuilder
    ) throws {
        for entry in package.entries {
            let lowered = entry.name.lowercased()
            guard lowered.hasSuffix(".json") else { continue }
            let isMaterial = lowered.hasPrefix("materials/")
            let isEffect = lowered.hasPrefix("effects/") || lowered.contains("/effects/")
            guard isMaterial || isEffect else { continue }

            guard entry.dataSize <= 4 * 1024 * 1024 else { continue }
            if let data = try? package.readEntry(entry, from: handle) {
                ingestMaterialOrEffect(data: data, into: &builder)
            }
        }
    }

    private func ingestMaterialOrEffect(data: Data, into builder: inout ReportBuilder) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]) as? [String: Any] else {
            return
        }
        Self.collectShaderNames(in: json, into: &builder)
    }

    private static func collectShaderNames(in node: Any, into builder: inout ReportBuilder) {
        if let dict = node as? [String: Any] {
            if let shader = dict["shader"] as? String, !shader.isEmpty {
                builder.note(shaderName: shader)
            }
            for value in dict.values {
                collectShaderNames(in: value, into: &builder)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collectShaderNames(in: value, into: &builder)
            }
        }
    }

    /// Mirrors `WPESceneDocumentParser.objectKindResolution` for one object dict.
    static func classifyObject(_ entry: [String: Any]) -> WPESceneObjectKind {
        if let explicit = (entry["type"] as? String)?.lowercased(), !explicit.isEmpty {
            switch explicit {
            case "image", "model": return .image
            case "sound":    return .sound
            case "particle": return .particle
            case "text":     return .text
            case "light":    return .light
            default:         break
            }
        }
        if entry["image"] != nil || entry["model"] != nil { return .image }
        if entry["sound"] != nil    { return .sound }
        if entry["particle"] != nil { return .particle }
        if entry["text"] != nil     { return .text }
        if entry["light"] != nil    { return .light }
        return .unknown
    }
}

// MARK: - Report

/// Field names intentionally mirror the assertions in the project's plan file
/// so the gate test reads naturally.
struct WPECorpusReport: Equatable, Sendable {
    let projectCounts: [WPEType: Int]
    let scenePackageCount: Int
    /// Keys include the leading dot (`.tex`, `.vert`).
    let entryExtensionCounts: [String: Int]
    let objectKindCounts: [WPESceneObjectKind: Int]
    let scenesWithShaderSources: Int
    let sceneFeatureCounts: [WPESceneFeatureFlag: Int]
    let topShaderNames: [(name: String, count: Int)]
    let scanErrors: [String]

    static func == (lhs: WPECorpusReport, rhs: WPECorpusReport) -> Bool {
        lhs.projectCounts == rhs.projectCounts
            && lhs.scenePackageCount == rhs.scenePackageCount
            && lhs.entryExtensionCounts == rhs.entryExtensionCounts
            && lhs.objectKindCounts == rhs.objectKindCounts
            && lhs.scenesWithShaderSources == rhs.scenesWithShaderSources
            && lhs.sceneFeatureCounts == rhs.sceneFeatureCounts
            && lhs.scanErrors == rhs.scanErrors
            && lhs.topShaderNames.map(\.name) == rhs.topShaderNames.map(\.name)
            && lhs.topShaderNames.map(\.count) == rhs.topShaderNames.map(\.count)
    }
}

// WPESceneFeatureFlag was moved to LiveWallpaperCore/Schema/WPEScenePreflightTier.swift
// (lives alongside its sibling tier enum since SceneDescriptor carries both).

struct WPESceneFeatureSet: Equatable, Sendable {
    private(set) var flags: Set<WPESceneFeatureFlag> = []

    mutating func insert(_ flag: WPESceneFeatureFlag) { flags.insert(flag) }
}

private struct ReportBuilder {
    var projectCounts: [WPEType: Int] = [:]
    var scenePackageCount = 0
    var entryExtensionCounts: [String: Int] = [:]
    var objectKindCounts: [WPESceneObjectKind: Int] = [:]
    var scenesWithShaderSources = 0
    var sceneFeatureCounts: [WPESceneFeatureFlag: Int] = [:]
    var shaderNameCounts: [String: Int] = [:]
    var scanErrors: [String] = []
    private var lastSceneFeatureSet = WPESceneFeatureSet()
    private var pendingSceneShaderSourcesFlag = false

    mutating func note(projectType: WPEType) {
        projectCounts[projectType, default: 0] += 1
    }

    mutating func note(scenePackagePresent: Bool) {
        if scenePackagePresent { scenePackageCount += 1 }
        lastSceneFeatureSet = WPESceneFeatureSet()
        pendingSceneShaderSourcesFlag = false
    }

    mutating func note(entry name: String) {
        let ext = ("." + (name as NSString).pathExtension).lowercased()
        guard ext != "." else { return }
        entryExtensionCounts[ext, default: 0] += 1
    }

    mutating func note(shaderSourcesPresent: Bool) {
        if shaderSourcesPresent {
            scenesWithShaderSources += 1
            pendingSceneShaderSourcesFlag = true
        }
    }

    mutating func note(objectKind kind: WPESceneObjectKind) {
        objectKindCounts[kind, default: 0] += 1
    }

    mutating func note(sceneFeatureSet set: WPESceneFeatureSet) {
        lastSceneFeatureSet = set
        var combined = set
        if pendingSceneShaderSourcesFlag {
            combined.insert(.customShaderSource)
        }
        for flag in combined.flags {
            sceneFeatureCounts[flag, default: 0] += 1
        }
    }

    mutating func note(shaderName: String) {
        shaderNameCounts[shaderName, default: 0] += 1
    }

    mutating func note(missingProjectJSON folder: String) {
        scanErrors.append("missing project.json: \(folder)")
    }

    mutating func note(sceneJSONMissing folder: String) {
        scanErrors.append("missing scene entry: \(folder)")
    }

    mutating func note(malformedSceneJSON _: Bool) {
        scanErrors.append("malformed scene.json")
    }

    mutating func note(scanError: Error, at url: URL) {
        scanErrors.append("\(url.lastPathComponent): \(scanError)")
    }

    func finish() -> WPECorpusReport {
        let topShaders = shaderNameCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(32)
            .map { (name: $0.key, count: $0.value) }
        return WPECorpusReport(
            projectCounts: projectCounts,
            scenePackageCount: scenePackageCount,
            entryExtensionCounts: entryExtensionCounts,
            objectKindCounts: objectKindCounts,
            scenesWithShaderSources: scenesWithShaderSources,
            sceneFeatureCounts: sceneFeatureCounts,
            topShaderNames: Array(topShaders),
            scanErrors: scanErrors
        )
    }
}
#endif
