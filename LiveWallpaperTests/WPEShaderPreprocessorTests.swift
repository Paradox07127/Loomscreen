import Foundation
import Testing
@testable import LiveWallpaper

struct WPEShaderPreprocessorTests {

    @Test("Parses combo declaration")
    func parsesComboDeclaration() {
        let line = #"// [COMBO] {"material":"My", "combo":"FLOW", "type":"options", "default":1}"#
        let combo = WPEComboDeclaration.parse(line: line)
        #expect(combo == WPEComboDeclaration(
            combo: "FLOW", material: "My", comboType: "options", defaultValue: 1
        ))
    }

    @Test("Parses bind declaration")
    func parsesBindDeclaration() {
        let line = #"// [BIND] {"name":"diffuse", "index":0}"#
        let bind = WPEBindDeclaration.parse(line: line)
        #expect(bind == WPEBindDeclaration(slot: 0, name: "diffuse"))
    }

    @Test("Bakes combo defaults into preamble")
    func bakesCombosIntoPreamble() throws {
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let source = #"""
        // [COMBO] {"combo":"BLUR", "type":"options", "default":2}
        void main() { gl_FragColor = vec4(0,0,0,1); }
        """#

        let result = try processor.processStage(
            stage: .fragment,
            shaderName: "test",
            source: source,
            comboValues: [:]
        )

        #expect(result.combos["BLUR"]?.defaultValue == 2)
        #expect(result.source.contains("#define BLUR 2"))
    }

    @Test("Combo values override declared defaults")
    func comboValuesOverrideDefaults() throws {
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let source = #"""
        // [COMBO] {"combo":"GLOW", "type":"options", "default":0}
        void main() {}
        """#

        let result = try processor.processStage(
            stage: .vertex,
            shaderName: "x",
            source: source,
            comboValues: ["GLOW": 1]
        )

        #expect(result.source.contains("#define GLOW 1"))
        #expect(!result.source.contains("#define GLOW 0"))
    }

    @Test("Translates texSample2D to texture")
    func translatesTexSample2D() throws {
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let source = "void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }"
        let result = try processor.processStage(
            stage: .fragment,
            shaderName: "x",
            source: source,
            comboValues: [:]
        )
        #expect(result.source.contains("texture(g_Texture0, vec2(0.5))"))
        #expect(!result.source.contains("texSample2D("))
    }

    @Test("Replaces gl_FragColor with explicit out variable")
    func replacesGLFragColor() throws {
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let source = "void main() { gl_FragColor = vec4(1.0); }"
        let result = try processor.processStage(
            stage: .fragment,
            shaderName: "x",
            source: source,
            comboValues: [:]
        )
        #expect(result.source.contains("out vec4 wpe_fragColor"))
        #expect(result.source.contains("wpe_fragColor = vec4(1.0)"))
        #expect(!result.source.contains("gl_FragColor"))
    }

    @Test("Resolves include via resolver")
    func resolvesInclude() throws {
        let processor = WPEShaderPreprocessor { path, _ in
            path == "common.h" ? "#define COMMON_OK 1" : nil
        }
        let source = #"""
        #include "common.h"
        void main() {}
        """#

        let result = try processor.processStage(
            stage: .fragment,
            shaderName: "x",
            source: source,
            comboValues: [:]
        )

        #expect(result.source.contains("#define COMMON_OK 1"))
        #expect(result.source.contains("// [BEGIN INCLUDE common.h]"))
    }

    @Test("CRLF source keeps the body after an #include (newline normalization)")
    func crlfIncludeKeepsBody() throws {
        // Regression: WPE ships shaders (and most Windows workshop content) with
        // CRLF endings. Swift treats "\r\n" as one grapheme, so a Character-based
        // split saw the whole file as a single line — when that line started with
        // `#include`, the entire body (incl. `void main`) was swallowed and
        // dropped, and the shader failed to compile for every combo.
        let processor = WPEShaderPreprocessor { path, _ in
            path == "common.h" ? "#define COMMON_OK 1\r\nfloat helper() { return 1.0; }" : nil
        }
        let source = "#include \"common.h\"\r\nuniform vec4 g_Color4;\r\nvoid main() { gl_FragColor = g_Color4; }\r\n"

        let result = try processor.processStage(
            stage: .fragment,
            shaderName: "font",
            source: source,
            comboValues: [:]
        )

        #expect(result.source.contains("void main"))
        #expect(result.source.contains("g_Color4"))
        #expect(result.source.contains("helper"))           // included body survived too
        #expect(!result.source.contains("\r"))              // endings normalized to LF
    }

    @Test("Throws when include cannot be resolved")
    func includeMissingThrows() {
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let source = #"""
        #include "nope.h"
        void main() {}
        """#

        #expect(throws: WPEShaderCompilerError.self) {
            _ = try processor.processStage(
                stage: .vertex,
                shaderName: "x",
                source: source,
                comboValues: [:]
            )
        }
    }

    @Test("Hash is stable across runs and combo ordering")
    func hashIsStable() {
        let h1 = WPEShaderPreprocessor.stableHash(
            shaderName: "img4",
            vertexSource: "v",
            fragmentSource: "f",
            comboValues: ["A": 1, "B": 2]
        )
        let h2 = WPEShaderPreprocessor.stableHash(
            shaderName: "img4",
            vertexSource: "v",
            fragmentSource: "f",
            comboValues: ["B": 2, "A": 1]
        )
        #expect(h1 == h2)

        let h3 = WPEShaderPreprocessor.stableHash(
            shaderName: "img4",
            vertexSource: "v",
            fragmentSource: "f",
            comboValues: ["A": 1, "B": 3]
        )
        #expect(h1 != h3)
    }

    @Test("Material textures override shader bind defaults")
    func materialTexturesOverrideBindDefaults() throws {
        let processor = WPEShaderPreprocessor { _, _ in nil }
        let vert = "void main() {}"
        let frag = #"""
        // [BIND] {"name":"baseShaderDefault", "index":0}
        void main() {}
        """#
        let request = try processor.process(
            shaderName: "x",
            vertexSource: vert,
            fragmentSource: frag,
            comboValues: [:],
            materialTextureBindings: [0: "materialOverride"]
        )
        #expect(request.textureBindings[0] == "materialOverride")
    }

}
