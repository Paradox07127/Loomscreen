import Foundation
import Testing

@Suite("macOS compatibility policy")
struct MacOSCompatibilityPolicyTests {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "LiveWallpaperTests" {
            url.deleteLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    @Test("project and package manifests target macOS 14")
    func deploymentTargetsAreMacOS14() throws {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("LiveWallpaper.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        #expect(!project.contains("MACOSX_DEPLOYMENT_TARGET = 26.0;"))
        #expect(project.contains("MACOSX_DEPLOYMENT_TARGET = 14.0;"))

        let sharedUI = try packageManifest("LiveWallpaperSharedUI")
        let proFeatures = try packageManifest("LiveWallpaperProFeatures")
        #expect(sharedUI.contains("platforms: [.macOS(.v14)]"))
        #expect(proFeatures.contains("platforms: [.macOS(.v14)]"))
    }

    @Test("Liquid Glass APIs stay inside AdaptiveGlass")
    func liquidGlassAPIsAreCentralized() throws {
        let allowed = "Packages/LiveWallpaperSharedUI/Sources/LiveWallpaperSharedUI/Components/AdaptiveGlass.swift"
        let needles = [
            "GlassEffectContainer",
            ".glassEffect(",
            ".buttonStyle(.glass)",
            ".buttonStyle(.glassProminent)",
            // Bare Glass-literal expressions used outside .glassEffect(...) —
            // e.g. ternaries selecting between two Glass values stored separately.
            // These are also macOS 26-only and must not survive the migration.
            "Glass.regular",
            ".regular.tint(",
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

    /// Strip single-line `// …` comments so explanatory notes like
    /// `// macOS 26 Liquid Glass` don't false-positive against our needle list.
    /// String literals containing `//` are rare in this codebase and would only
    /// cause a *more* conservative reading, never a false negative.
    private func stripLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let commentRange = line.range(of: "//") {
                    return line[line.startIndex..<commentRange.lowerBound]
                }
                return line
            }
            .joined(separator: "\n")
    }

    private func packageManifest(_ packageName: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/\(packageName)/Package.swift"),
            encoding: .utf8
        )
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
                collected.append(url)
            }
            return collected
        }
    }
}
