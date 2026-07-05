import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// `MSDF=1` exercises the `screenRangePx`/`ddx`/`ddy`/`CAST2` path that the
/// CoreText fallback was masking; `MSDF=0` is the raster control. File scope so
/// the `@MainActor` suite's parameterized `arguments:` (evaluated nonisolated)
/// can read it.
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

/// End-to-end compile gate for the GPU MSDF text path. Runs the SHIPPED
/// clean-room `shaders/font.frag` from `wpe-builtins.bundle` — the exact bytes
/// `resolveMSDFFontFragmentSource()` hands to `WPEMSDFTextRenderer` at runtime —
/// through the exact pipeline the renderer uses (`WPEShaderPreprocessor.process`
/// → `WPESwiftShaderCompiler.compile`) for every MSDF combo set.
///
/// This is the gate that decides whether MSDF text actually renders or silently
/// falls back to CoreText: if the bundled font.frag won't translate+compile, the
/// runtime throws and every scene reverts to the CoreText overlay. The fixture
/// is the shipped file itself, so the test fails for the same reason the device
/// would.
@MainActor
@Suite("Bundled clean-room font.frag MSDF compile gate")
struct WPEMSDFFontFragCompileTests {

    /// The shipped shader bytes, loaded from the app-bundled built-ins — no
    /// embedded fixture copy, so the test cannot drift from what users run.
    private static func bundledFontFragSource() throws -> String {
        let rootURL = try #require(WPEBuiltinFrameworkAssets.rootURL)
        let url = rootURL
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent("font.frag")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The bundled shader is self-contained (no `#include`), so the include
    /// resolver intentionally returns nil — an unexpected include is a failure.
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

    /// Regression gate for the preprocessor's newline normalization: externally
    /// provisioned shader sources (engine-assets installs) arrive with CRLF line
    /// endings, and without normalization the whole file collapses onto a single
    /// preprocessor line. Feed the shipped shader as CRLF to keep that path hot.
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
