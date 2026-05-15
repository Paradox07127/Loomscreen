import Foundation

/// Read-only inventory of a Wallpaper Engine corpus directory (e.g. a Steam
/// Workshop sync folder). Drives the regression gate: every later phase is
/// validated by re-scanning the corpus and asserting the report matches the
/// expected feature counts. The scanner never extracts a full `scene.pkg` —
/// it streams the package index and reads only the JSON entries it needs to
/// classify object kinds and shader names.
struct WPECorpusScanner {
    /// Filesystem root containing one subfolder per workshop project.
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// Walks the corpus and produces a deterministic feature report. Async
    /// so callers can offload the I/O off the main actor; ordering of the
    /// per-scene tallies is by workshop ID for reproducibility.
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
            // Some workshop scenes ship unpacked. We mirror them in the
            // import path; counting them here keeps the report honest.
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

        // Walk the directory tree FIRST so the shader-source flag is set on
        // the builder before `ingestSceneJSON` commits this scene's feature
        // set. Material/effect JSONs feed the top-shader ledger; the actual
        // scene JSON parse comes last so its feature set sees every flag.
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

            // Bound the per-entry read; material/effect JSONs are tiny.
            // A 4 MB upper bound covers every observed file by 100×.
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

    /// Mirrors `WPESceneDocumentParser.objectKindResolution` for one object
    /// dict. Kept private to the scanner because the parser keeps its own
    /// resolution type for diagnostics; the scanner only needs the primary
    /// kind to bucket counts.
    static func classifyObject(_ entry: [String: Any]) -> WPESceneObjectKind {
        if let explicit = (entry["type"] as? String)?.lowercased(), !explicit.isEmpty {
            switch explicit {
            case "image":    return .image
            case "sound":    return .sound
            case "particle": return .particle
            case "text":     return .text
            case "light":    return .light
            default:         break
            }
        }
        if entry["image"] != nil    { return .image }
        if entry["sound"] != nil    { return .sound }
        if entry["particle"] != nil { return .particle }
        if entry["text"] != nil     { return .text }
        if entry["light"] != nil    { return .light }
        return .unknown
    }
}

// MARK: - Report

/// Aggregated counts produced by `WPECorpusScanner.scan()`. Field names
/// intentionally mirror the assertions in the project's plan file so the
/// gate test reads naturally. Equatable for snapshot tests.
struct WPECorpusReport: Equatable, Sendable {
    /// Project type → count.
    let projectCounts: [WPEType: Int]
    /// Number of scene projects shipping a `scene.pkg` (vs unpacked).
    let scenePackageCount: Int
    /// File extension → count across every entry inside every scene package.
    /// Keys include the leading dot (`.tex`, `.vert`).
    let entryExtensionCounts: [String: Int]
    /// Per-object-kind tally summed over every scene's `scene.json`.
    let objectKindCounts: [WPESceneObjectKind: Int]
    /// Number of scene packages containing at least one `.vert` or `.frag`.
    let scenesWithShaderSources: Int
    /// Per-feature scene count: how many scene packages declare each flag.
    let sceneFeatureCounts: [WPESceneFeatureFlag: Int]
    /// Top shader names referenced from material/effect JSONs, sorted by
    /// descending occurrence. Truncated to a reasonable cap.
    let topShaderNames: [(name: String, count: Int)]
    /// Per-folder errors encountered during scanning. Empty in the happy
    /// path; populated when project.json is malformed or an entry fails to
    /// decode.
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

/// Per-scene capability bits — driven by the JSON content, not the renderer's
/// current ability to handle them. The preflight classifier consumes this to
/// decide which tier the scene gets.
enum WPESceneFeatureFlag: String, Codable, Hashable, Sendable {
    case customShaderSource
    case particleObject
    case textObject
    case soundObject
    case lightObject
    case animationLayer
    case imageEffect
    case unknownObject
    case windowsPlugin
}

struct WPESceneFeatureSet: Equatable, Sendable {
    private(set) var flags: Set<WPESceneFeatureFlag> = []

    mutating func insert(_ flag: WPESceneFeatureFlag) { flags.insert(flag) }
    func contains(_ flag: WPESceneFeatureFlag) -> Bool { flags.contains(flag) }
    var isEmpty: Bool { flags.isEmpty }
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
        // Each new scene resets the per-scene feature accumulator.
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
