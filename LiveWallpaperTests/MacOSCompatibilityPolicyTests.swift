import Foundation
import Testing

@Suite("macOS compatibility policy")
struct MacOSCompatibilityPolicyTests {
    private var repoRoot: URL { RepositoryRoot.url }

    @Test("project and package manifests target macOS 14")
    func deploymentTargetsAreMacOS14() throws {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("LiveWallpaper.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let projectTargets = project
            .matches(of: /MACOSX_DEPLOYMENT_TARGET = ([^;]+);/)
            .map { String($0.output.1) }
        #expect(!projectTargets.isEmpty)
        #expect(
            Set(projectTargets) == ["14.0"],
            Comment(rawValue: "pbxproj has non-14.0 deployment targets: \(Set(projectTargets).sorted())")
        )

        for (name, manifest) in try allPackageManifests() {
            #expect(
                manifest.contains("platforms: [.macOS(.v14)]"),
                Comment(rawValue: "\(name) does not declare platforms: [.macOS(.v14)]")
            )
        }
    }

    @Test("Liquid Glass APIs stay inside AdaptiveGlass")
    func liquidGlassAPIsAreCentralized() throws {
        let allowed = "Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Components/AdaptiveGlass.swift"
        let needles = [
            "GlassEffectContainer",
            ".glassEffect(",
            ".glassEffectID(",
            ".glassEffectUnion(",
            ".glassEffectTransition(",
            "DefaultGlassEffectShape",
            ".buttonStyle(.glass)",
            ".buttonStyle(.glass(",
            ".buttonStyle(.glassProminent)",
            "GlassButtonStyle",
            "GlassProminentButtonStyle",
            "Glass.regular",
            "Glass.clear",
            "Glass.identity",
            ".regular.tint(",
            ".regular.interactive(",
        ]

        let offenders = try swiftFiles()
            .filter { !$0.path.hasSuffix(allowed) }
            .flatMap { file -> [String] in
                let raw = try String(contentsOf: file, encoding: .utf8)
                let stripped = stripLineComments(raw)
                let relativePath = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                return needles
                    .filter { stripped.contains($0) }
                    .map { "\(relativePath) contains \($0)" }
            }

        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "\n")))
    }

    // MARK: - Helpers

    /// Strip `// …` line comments so explanatory notes like `// macOS 26 Liquid Glass` don't false-positive.
    private func stripLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = lineCommentStart(in: line) else { return line }
                return line[line.startIndex..<commentStart]
            }
            .joined(separator: "\n")
    }

    /// Returns the first `//` that begins a real line comment, skipping `//` nested inside `"…"` string literals.
    private func lineCommentStart(in line: Substring) -> Substring.Index? {
        var inString = false
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if escaped {
                escaped = false
            } else if inString && character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString && character == "/" {
                let next = line.index(after: index)
                if next < line.endIndex && line[next] == "/" {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private func allPackageManifests() throws -> [(name: String, contents: String)] {
        let packagesRoot = repoRoot.appendingPathComponent("Packages")
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(
            at: packagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .compactMap { dir -> (String, String)? in
                let manifest = dir.appendingPathComponent("Package.swift")
                guard manager.fileExists(atPath: manifest.path) else { return nil }
                let contents = try String(contentsOf: manifest, encoding: .utf8)
                return (dir.lastPathComponent, contents)
            }
    }

    private func swiftFiles() throws -> [URL] {
        let roots = [
            repoRoot.appendingPathComponent("LiveWallpaper"),
            repoRoot.appendingPathComponent("Packages"),
        ]
        let manager = FileManager.default
        return roots.flatMap { root -> [URL] in
            guard
                let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            else { return [] }
            var collected: [URL] = []
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }
                collected.append(url)
            }
            return collected
        }
    }
}
