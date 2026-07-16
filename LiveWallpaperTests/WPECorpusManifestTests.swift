#if !LITE_BUILD
import Darwin
import Foundation
import Testing

/// RR-03 E1 leaf: inventories the real local WPE corpus without loading renderer
/// code or reading/copying large wallpaper assets. The resulting manifest is
/// deterministic and contains no absolute user path, so it can be promoted to a
/// reviewed fixture when the corpus composition is intentionally locked.
@Suite("WPE corpus manifest")
struct WPECorpusManifestTests {
    @Test("Container corpus writes a deterministic path-redacted manifest")
    func containerCorpusWritesManifest() throws {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let liveWallpaperSupport = applicationSupport.appendingPathComponent("LiveWallpaper", isDirectory: true)
        let configURL = liveWallpaperSupport.appendingPathComponent("oracle-capture.json")

        let selection: CorpusSelection
        if fileManager.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(OracleCaptureRootConfig.self, from: data)
            try #require(!config.corpusRoot.isEmpty, "oracle-capture.json corpusRoot must not be empty")
            selection = CorpusSelection(
                root: URL(fileURLWithPath: config.corpusRoot, isDirectory: true),
                label: "oracle-capture-config"
            )
        } else {
            let canonicalRoot = applicationSupport
                .appendingPathComponent("Steam", isDirectory: true)
                .appendingPathComponent("steamapps", isDirectory: true)
                .appendingPathComponent("workshop", isDirectory: true)
                .appendingPathComponent("content", isDirectory: true)
                .appendingPathComponent("431960", isDirectory: true)
            guard fileManager.fileExists(atPath: canonicalRoot.path) else {
                print("[wpe-corpus-manifest] no oracle config or canonical container corpus — skipping")
                return
            }
            selection = CorpusSelection(root: canonicalRoot, label: "canonical-container-431960")
        }

        // A canonical/configured root that exists but cannot be enumerated, or is
        // unexpectedly empty, is a failed E1 lock rather than a clean skip.
        let first = try WPECorpusManifestBuilder.build(root: selection.root, rootLabel: selection.label)
        try #require(!first.entries.isEmpty, "configured/canonical WPE corpus contains no project directories")
        let firstData = try WPECorpusManifestBuilder.encode(first)
        let secondData = try WPECorpusManifestBuilder.encode(
            WPECorpusManifestBuilder.build(root: selection.root, rootLabel: selection.label)
        )
        #expect(firstData == secondData, "two unchanged corpus scans must be byte-identical")
        #expect(firstData.range(of: Data(selection.root.path.utf8)) == nil,
                "manifest must not contain corpus absolute path")

        let outputDirectory = liveWallpaperSupport
            .appendingPathComponent("oracle-out", isDirectory: true)
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent("corpus-manifest.json")
        try firstData.write(to: outputURL, options: .atomic)

        let typeSummary = first.summary.projectTypes
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        print("[wpe-corpus-manifest] directories=\(first.summary.directories) "
              + "captureCandidates=\(first.summary.captureCandidates) types=\(typeSummary)")
        print("[wpe-corpus-manifest] entries="
              + first.entries.map { "\($0.folderID):\($0.projectType)" }.joined(separator: ","))
        print("[wpe-corpus-manifest] wrote \(outputURL.path)")
    }

    @Test("Manifest builder is sorted, repeatable, and never serializes its root")
    func builderIsRepeatableAndPathRedacted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("wpe-manifest-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.makeProject(
            id: "10",
            manifest: ["workshopid": 10, "type": "scene", "file": "scene.json"],
            root: root
        )
        try Data("fixture".utf8).write(to: root.appendingPathComponent("10/scene.pkg"))
        try Self.makeProject(
            id: "2",
            manifest: ["workshopid": "2", "type": "web", "file": "index.html"],
            root: root
        )
        try Data("ok".utf8).write(to: root.appendingPathComponent("2/index.html"))
        let malformed = root.appendingPathComponent("3", isDirectory: true)
        try fileManager.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: malformed.appendingPathComponent("project.json"))

        let first = try WPECorpusManifestBuilder.build(root: root, rootLabel: "test-fixture")
        let firstData = try WPECorpusManifestBuilder.encode(first)
        let secondData = try WPECorpusManifestBuilder.encode(
            WPECorpusManifestBuilder.build(root: root, rootLabel: "test-fixture")
        )

        #expect(firstData == secondData)
        #expect(firstData.range(of: Data(root.path.utf8)) == nil)
        #expect(first.entries.map(\.folderID) == ["10", "2", "3"])
        #expect(first.summary.directories == 3)
        #expect(first.summary.captureCandidates == 1)
        #expect(first.entries[0].accessibility.scenePackageReadable)
        #expect(first.entries[2].accessibility.projectJSON == "malformed")
    }

    private static func makeProject(id: String, manifest: [String: Any], root: URL) throws {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("project.json"))
    }
}

private struct OracleCaptureRootConfig: Decodable {
    let corpusRoot: String
}

private struct CorpusSelection {
    let root: URL
    let label: String
}

private enum WPECorpusManifestBuilder {
    static let schema = "wpe.corpus-manifest.v1"
    static let maxProjectJSONBytes = 2 * 1024 * 1024

    static func build(root: URL, rootLabel: String) throws -> WPECorpusManifest {
        try requireRootLabel(rootLabel)
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WPECorpusManifestError.invalidRoot
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let folders = try children.filter { child in
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let entries = folders.map(scanProject)

        var projectTypes: [String: Int] = [:]
        var projectJSONStates: [String: Int] = [:]
        for entry in entries {
            projectTypes[entry.projectType, default: 0] += 1
            projectJSONStates[entry.accessibility.projectJSON, default: 0] += 1
        }
        return WPECorpusManifest(
            schema: schema,
            rootLabel: rootLabel,
            summary: .init(
                directories: entries.count,
                captureCandidates: entries.filter(\.captureCandidate).count,
                projectTypes: projectTypes,
                projectJSONStates: projectJSONStates
            ),
            entries: entries
        )
    }

    static func encode(_ manifest: WPECorpusManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        return data
    }

    private static func scanProject(_ folder: URL) -> WPECorpusManifest.Entry {
        let folderID = folder.lastPathComponent
        let projectURL = folder.appendingPathComponent("project.json")
        var state = "missing"
        var issues: Set<String> = []
        var workshopID: String? = safeComponent(folderID) ? folderID : nil
        var projectType = "unknown"
        var entryFile: String?

        do {
            let values = try projectURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                state = "unreadable"
                issues.insert("projectJSONNotRegularFile")
                issues.insert("projectJSONUnreadable")
                return makeEntry(
                    folder: folder, folderID: folderID, workshopID: workshopID,
                    projectType: projectType, entryFile: entryFile, state: state, issues: issues
                )
            }
            if let fileSize = values.fileSize, fileSize > maxProjectJSONBytes {
                state = "tooLarge"
                issues.insert("projectJSONExceedsReadLimit")
                issues.insert("projectJSONTooLarge")
                return makeEntry(
                    folder: folder, folderID: folderID, workshopID: workshopID,
                    projectType: projectType, entryFile: entryFile, state: state, issues: issues
                )
            }
            let data = try boundedProjectJSONData(at: projectURL)
            guard data.count <= maxProjectJSONBytes else {
                state = "tooLarge"
                issues.insert("projectJSONExceedsReadLimit")
                issues.insert("projectJSONTooLarge")
                return makeEntry(
                    folder: folder, folderID: folderID, workshopID: workshopID,
                    projectType: projectType, entryFile: entryFile, state: state, issues: issues
                )
            }
            let decoded: [String: Any]
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw WPECorpusManifestError.invalidProjectJSON
                }
                decoded = object
            } catch {
                throw WPECorpusManifestError.invalidProjectJSON
            }
            state = "readable"
            if let declaredID = flexibleString(decoded["workshopid"]) {
                if safeComponent(declaredID) {
                    workshopID = declaredID
                    if declaredID != folderID { issues.insert("workshopIDDiffersFromFolder") }
                } else {
                    issues.insert("unsafeWorkshopID")
                }
            }
            if let rawType = flexibleString(decoded["type"])?.lowercased(),
               ["scene", "web", "video", "application"].contains(rawType) {
                projectType = rawType
            }
            if let declaredEntry = flexibleString(decoded["file"]) {
                if safeRelativePath(declaredEntry) {
                    entryFile = declaredEntry
                } else {
                    issues.insert("unsafeEntryFile")
                }
            } else {
                issues.insert("missingEntryFile")
            }
        } catch WPECorpusManifestError.invalidProjectJSON {
            state = "malformed"
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            state = "missing"
        } catch {
            state = "unreadable"
        }
        if state != "readable" {
            issues.insert("projectJSON\(state.prefix(1).uppercased())\(state.dropFirst())")
        }
        return makeEntry(
            folder: folder, folderID: folderID, workshopID: workshopID,
            projectType: projectType, entryFile: entryFile, state: state, issues: issues
        )
    }

    private static func boundedProjectJSONData(at url: URL) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(descriptor)
            throw POSIXError(code)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw WPECorpusManifestError.projectJSONNotRegular
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxProjectJSONBytes + 1) ?? Data()
    }

    private static func makeEntry(
        folder: URL,
        folderID: String,
        workshopID: String?,
        projectType: String,
        entryFile: String?,
        state: String,
        issues: Set<String>
    ) -> WPECorpusManifest.Entry {
        let entryReadable = entryFile.map { readableRegularFile(folder.appendingPathComponent($0)) } ?? false
        let sceneJSONReadable = readableRegularFile(folder.appendingPathComponent("scene.json"))
        let scenePackageReadable = readableRegularFile(folder.appendingPathComponent("scene.pkg"))
        return .init(
            folderID: folderID,
            workshopID: workshopID,
            projectType: projectType,
            entryFile: entryFile,
            accessibility: .init(
                projectJSON: state,
                entryFileReadable: entryReadable,
                sceneJSONReadable: sceneJSONReadable,
                scenePackageReadable: scenePackageReadable
            ),
            captureCandidate: state == "readable"
                && projectType == "scene"
                && entryFile != nil
                && (entryReadable || scenePackageReadable),
            issues: issues.sorted()
        )
    }

    private static func readableRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func flexibleString(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if value is Bool { return nil }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("..")
    }

    private static func safeRelativePath(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty
            && !value.hasPrefix("/")
            && !value.contains("\\")
            && !components.contains("..")
            && !components.contains(".")
            && !components.contains("")
    }

    private static func requireRootLabel(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...64).contains(value.count), value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw WPECorpusManifestError.invalidRootLabel
        }
    }
}

private struct WPECorpusManifest: Codable, Equatable {
    let schema: String
    let rootLabel: String
    let summary: Summary
    let entries: [Entry]

    struct Summary: Codable, Equatable {
        let directories: Int
        let captureCandidates: Int
        let projectTypes: [String: Int]
        let projectJSONStates: [String: Int]
    }

    struct Entry: Codable, Equatable {
        let folderID: String
        let workshopID: String?
        let projectType: String
        let entryFile: String?
        let accessibility: Accessibility
        let captureCandidate: Bool
        let issues: [String]
    }

    struct Accessibility: Codable, Equatable {
        let projectJSON: String
        let entryFileReadable: Bool
        let sceneJSONReadable: Bool
        let scenePackageReadable: Bool
    }
}

private enum WPECorpusManifestError: Error {
    case invalidRoot
    case invalidRootLabel
    case invalidProjectJSON
    case projectJSONNotRegular
}
#endif
