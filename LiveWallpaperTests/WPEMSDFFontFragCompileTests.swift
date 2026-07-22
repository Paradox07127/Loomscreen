import Foundation
import Metal
import Testing
@testable import LiveWallpaper

private let msdfFontCombos: [[String: Int]] = [
    ["MSDF": 0, "COLORFONT": 0],
    ["MSDF": 0, "COLORFONT": 1],
    ["MSDF": 1, "OUTLINE_ENABLED": 0, "BLUR_ENABLED": 0, "DROP_SHADOW_ENABLED": 0, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 0, "DROP_SHADOW_ENABLED": 0, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 0, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 0, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 0, "BLUR_ENABLED": 0, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 0],
    ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 1]
]

@MainActor
@Suite("Bundled clean-room font.frag MSDF compile gate")
struct WPEMSDFFontFragCompileTests {

    private static func bundledFontFragSource() throws -> String {
        let rootURL = try #require(WPEBuiltinFrameworkAssets.rootURL)
        let url = rootURL
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent("font.frag")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func compile(source: String, combos: [String: Int]) throws {
        let preprocessor = WPEShaderPreprocessor { _, _ in nil }
        let preludedFragment = WPEShaderBuiltinMacros.glslPrelude + "\n" + source
        let request = try preprocessor.process(
            shaderName: "font",
            vertexSource: "#version 410 core\nvoid main() {}",
            fragmentSource: preludedFragment,
            comboValues: combos,
            materialTextureBindings: [:]
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        _ = try WPESwiftShaderCompiler(device: device).compile(request)
    }

    @Test(
        "Bundled font.frag translates + compiles for every MSDF combo",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil),
        arguments: msdfFontCombos
    )
    func fontFragCompiles(combo: [String: Int]) throws {
        try compile(source: try Self.bundledFontFragSource(), combos: combo)
    }

    @Test(
        "CRLF-fed font.frag still translates + compiles (newline normalization)",
        .enabled(if: WPEBuiltinFrameworkAssets.rootURL != nil)
    )
    func fontFragCompilesWithCRLFLineEndings() throws {
        let crlfSource = try Self.bundledFontFragSource()
            .replacingOccurrences(of: "\n", with: "\r\n")
        try compile(
            source: crlfSource,
            combos: ["MSDF": 1, "OUTLINE_ENABLED": 1, "BLUR_ENABLED": 1, "DROP_SHADOW_ENABLED": 1, "COLORFONT": 1]
        )
    }
}
