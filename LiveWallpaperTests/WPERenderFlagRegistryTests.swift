import Foundation
import Testing

/// Source-scan guard for the `renderFlagKeys` bug-report registry in
/// `WPESceneDetailView`: every `defaults` key the renderer stack reads must
/// either appear in `renderFlagKeys` or carry an exclusion reason below, so a
/// new flag (e.g. a kill-switch added with a feature) cannot silently drift
/// out of the "Flags:" line in bug reports.
///
/// The scan covers the three idioms renderer code uses to reach UserDefaults:
/// a literal key at the call site (`…(forKey: "WPE…")`), a `…DefaultsKey`
/// constant read via `forKey: Self.…`, and the suite-aware
/// `puppetDefaultsFlagOptional("WPE…")` helper. A flag read through a new
/// idiom needs a matching pattern in `defaultsKeyPatterns`.
@Suite("WPE render flag registry")
struct WPERenderFlagRegistryTests {

    private static let registryPath = "LiveWallpaper/Views/ScreenDetail/WPESceneDetailView.swift"

    /// Directories that make up the scene renderer stack.
    private static let rendererRoots = [
        "LiveWallpaper/Runtime",
        "LiveWallpaper/Infrastructure",
        "Packages/LiveWallpaperProWPE/Sources",
    ]

    /// Renderer-read keys deliberately absent from `renderFlagKeys`, each with
    /// its reason. New keys belong in `renderFlagKeys` unless they clearly
    /// never change what renders.
    private static let excludedKeys: [String: String] = [
        "WPEAudioDebugLog": "log-only toggle; never changes what renders",
        "WPEDumpLayerPasses": "dump/trace toggle; prints per-layer pass dumps only",
        "WPEDumpScenePasses": "dump/trace toggle; prints the scene pass structure only",
        "WPEHoverCursorDebug": "log-only toggle; never changes what renders",
        "WPEImageUniformDebugLog": "log-only toggle; never changes what renders",
        "WPELibrary.RootBookmark.v1": "persisted security-scoped bookmark blob, not a flag",
        "WPEMetalCaptureScene": "dump/trace toggle; records canonical oracle traces only",
        "WPEOracleEnabled": "DEBUG-only render-oracle master toggle; inert in Release (seeds RNG + freezes the clock only for trace determinism)",
        "WPEOracleFreezeTime": "DEBUG-only oracle frozen scene time; inert in Release",
        "WPEOraclePerPassHashes": "DEBUG-only oracle per-pass hashing opt-in; inert in Release",
        "WPEOracleReplayTime": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEOracleReplayDaytime": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEOracleReplayPointerX": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPEOracleReplayPointerY": "DEBUG-only oracle fidelity-replay frame global; inert in Release",
        "WPESceneDebugArtifactsEnabled": "dump/trace toggle; writes debug artifacts and extra logs only",
    ]

    @Test("Every renderer defaults key is registered or explicitly excluded")
    func rendererKeysAreRegisteredOrExcluded() throws {
        let discovered = try Self.rendererDefaultsKeys()
        let registered = try Self.registeredRenderFlagKeys()
        let missing = discovered.subtracting(registered).subtracting(Self.excludedKeys.keys)
        #expect(missing.isEmpty, Comment(rawValue: """
            The renderer stack reads defaults keys that WPESceneDetailView.renderFlagKeys \
            does not surface in bug reports. Add each to renderFlagKeys (render-behaviour \
            flags) or to excludedKeys here with a one-line reason:
            \(missing.sorted().joined(separator: "\n"))
            """))
    }

    @Test("Registry and exclusion list track live keys only")
    func registryTracksLiveKeysOnly() throws {
        let discovered = try Self.rendererDefaultsKeys()
        let registered = try Self.registeredRenderFlagKeys()

        let staleRegistered = registered.subtracting(discovered)
        #expect(staleRegistered.isEmpty, Comment(rawValue: """
            renderFlagKeys lists keys the renderer stack no longer reads — remove them \
            (or teach the scan the new read idiom):
            \(staleRegistered.sorted().joined(separator: "\n"))
            """))

        let staleExcluded = Set(Self.excludedKeys.keys).subtracting(discovered)
        #expect(staleExcluded.isEmpty, Comment(rawValue: """
            excludedKeys lists keys the renderer stack no longer reads — remove them:
            \(staleExcluded.sorted().joined(separator: "\n"))
            """))

        let overlap = registered.intersection(Self.excludedKeys.keys)
        #expect(overlap.isEmpty, Comment(rawValue: """
            Keys cannot be both registered and excluded:
            \(overlap.sorted().joined(separator: "\n"))
            """))
    }

    // MARK: - Renderer source scanning

    private static func rendererDefaultsKeys() throws -> Set<String> {
        // The key charset includes "." for versioned keys (WPELibrary.RootBookmark.v1).
        let defaultsKeyPatterns = [
            /forKey:\s*"(WPE[A-Za-z0-9.]+)"/,
            /[Dd]efaultsKey\s*=\s*"(WPE[A-Za-z0-9.]+)"/,
            /puppetDefaultsFlagOptional\(\s*"(WPE[A-Za-z0-9.]+)"/,
        ]
        var keys: Set<String> = []
        for root in rendererRoots {
            let rootURL = projectURL(root)
            let files = try swiftFiles(under: rootURL)
            #expect(!files.isEmpty, "Renderer root moved — update rendererRoots: \(root)")
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                    // A comment naming a removed key must not count as a live read.
                    guard !line.drop(while: \.isWhitespace).hasPrefix("//") else { continue }
                    for pattern in defaultsKeyPatterns {
                        for match in line.matches(of: pattern) {
                            keys.insert(String(match.output.1))
                        }
                    }
                }
            }
        }
        try #require(!keys.isEmpty, "Scan found no defaults keys — the read patterns rotted")
        return keys
    }

    private static func registeredRenderFlagKeys() throws -> Set<String> {
        let source = try String(contentsOf: projectURL(registryPath), encoding: .utf8)
        let declaration = try #require(
            source.range(of: "let renderFlagKeys = ["),
            "renderFlagKeys declaration not found in \(registryPath)"
        )
        let close = try #require(
            source.range(of: "]", range: declaration.upperBound..<source.endIndex),
            "renderFlagKeys array literal is unterminated"
        )
        let body = source[declaration.upperBound..<close.lowerBound]
        let keys = Set(body.matches(of: /"([^"]+)"/).map { String($0.output.1) })
        try #require(!keys.isEmpty, "renderFlagKeys parsed as empty — extraction rotted")
        return keys
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        RepositoryRoot.swiftFiles(underURL: root)
    }

    private static func projectURL(_ relativePath: String) -> URL {
        RepositoryRoot.url(relativePath)
    }
}
