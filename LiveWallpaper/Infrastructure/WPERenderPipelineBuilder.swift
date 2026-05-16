#if !LITE_BUILD
import Foundation

struct WPERenderPipelineBuilder: Sendable {
    private let shaderLoader: WPEShaderSourceLoader

    init(cacheRootURL: URL, engineAssetsRootURL: URL? = nil) {
        self.shaderLoader = WPEShaderSourceLoader(
            cacheRootURL: cacheRootURL,
            engineAssetsRootURL: engineAssetsRootURL
        )
    }

    func build(graph: WPERenderGraph) throws -> WPEPreparedRenderPipeline {
        let layers = try graph.layers.map { layer in
            let passes = try layer.passes.map { pass in
                try preparedPass(for: pass)
            }
            return WPEPreparedRenderLayer(graphLayer: layer, passes: passes)
        }
        return WPEPreparedRenderPipeline(layers: layers)
    }

    private func preparedPass(for pass: WPERenderPass) throws -> WPEPreparedRenderPass {
        let shader = try shaderLoader.load(shaderName: pass.shader, pass: pass)
        return WPEPreparedRenderPass(
            pass: pass,
            shader: shader.program,
            textureBindings: shader.textureBindings,
            comboValues: shader.comboValues,
            uniformValues: shader.uniformValues
        )
    }
}

private struct WPEShaderLoadResult: Equatable, Sendable {
    let program: WPEShaderProgram
    let textureBindings: [Int: WPETextureReference]
    let comboValues: [String: Int]
    let uniformValues: [String: WPESceneShaderConstantValue]
}

private enum WPEShaderStage: Sendable {
    case vertex
    case fragment
}

private struct WPEShaderMetadata: Equatable, Sendable {
    let defaultTextures: [Int: WPETextureReference]
    let comboValues: [String: Int]
    let uniformValues: [String: WPESceneShaderConstantValue]
}

private struct WPEShaderUniformAnnotation {
    let type: String
    let name: String
    let metadata: [String: Any]
}

private struct WPEShaderSourceLoader: Sendable {
    private let resolver: WPEMultiRootResourceResolver

    init(cacheRootURL: URL, engineAssetsRootURL: URL? = nil) {
        // Reuse the same fall-through chain as scene-asset lookup so shader
        // `#include` resolution lands on the engine root for common helpers
        // (`common_composite.h`, `common_blur.h`, …) that WPE ships under
        // `assets/shaders/`.
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: [],
            engineAssetsRootURL: engineAssetsRootURL
        )
    }

    func load(shaderName: String, pass: WPERenderPass) throws -> WPEShaderLoadResult {
        if let builtin = builtinProgram(shaderName: shaderName, combos: pass.combos) {
            return WPEShaderLoadResult(
                program: builtin,
                textureBindings: textureBindings(for: pass, defaults: [:]),
                comboValues: pass.combos,
                uniformValues: pass.constants
            )
        }

        let vertexPath = "shaders/\(shaderName).vert"
        let fragmentPath = "shaders/\(shaderName).frag"
        let vertexSource = try readShaderSource(path: vertexPath, shaderName: shaderName, stage: "vertex")
        let fragmentSource = try readShaderSource(path: fragmentPath, shaderName: shaderName, stage: "fragment")
        let metadata = shaderMetadata(from: [vertexSource, fragmentSource], pass: pass)
        let comboValues = metadata.comboValues

        let program = WPEShaderProgram(
            name: shaderName,
            vertexSource: try preprocess(
                source: vertexSource,
                logicalPath: vertexPath,
                stage: .vertex,
                comboValues: comboValues,
                includeStack: []
            ),
            fragmentSource: try preprocess(
                source: fragmentSource,
                logicalPath: fragmentPath,
                stage: .fragment,
                comboValues: comboValues,
                includeStack: []
            ),
            isBuiltin: false
        )
        return WPEShaderLoadResult(
            program: program,
            textureBindings: textureBindings(for: pass, defaults: metadata.defaultTextures),
            comboValues: comboValues,
            uniformValues: metadata.uniformValues
        )
    }

    private func builtinProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram? {
        let normalized = WPEBuiltinShaderName.normalized(shaderName)
        switch normalized {
        case "solidcolor":
            return solidColorProgram(shaderName: shaderName, combos: combos)
        case "solidlayer":
            return solidLayerProgram(shaderName: shaderName, combos: combos)
        case "copy":
            return copyProgram(shaderName: shaderName, combos: combos)
        case "compose":
            return composeProgram(shaderName: shaderName, combos: combos)
        default:
            // Phase 2D-C: pre-compiled effects share `copyProgram`'s GLSL
            // skeleton because the runtime renders them through dedicated
            // MSL fragments — the prepared GLSL is only kept around for
            // future shader-translator paths.
            if normalized.hasPrefix("effect_") {
                return copyProgram(shaderName: shaderName, combos: combos)
            }
            guard WPEBuiltinShaderName.isGenericImageShader(shaderName) else {
                return nil
            }
            return copyProgram(shaderName: shaderName, combos: combos)
        }
    }

    private func solidLayerProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
        let vertex = """
        attribute vec3 a_Position;

        void main() {
            gl_Position = vec4(a_Position, 1.0);
        }
        """
        let fragment = """
        uniform vec4 g_Color;

        void main() {
            gl_FragColor = vec4(g_Color.rgb * g_Color.a, g_Color.a);
        }
        """
        return WPEShaderProgram(
            name: shaderName,
            vertexSource: shaderPrelude(comboValues: combos, stage: .vertex) + vertex,
            fragmentSource: shaderPrelude(comboValues: combos, stage: .fragment) + fragment.replacingOccurrences(
                of: "gl_FragColor",
                with: "out_FragColor"
            ),
            isBuiltin: true
        )
    }

    private func composeProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;

        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """
        let fragment = """
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        uniform vec4 g_Color;
        varying vec2 v_TexCoord;

        void main() {
            vec4 a = texSample2D(g_Texture0, v_TexCoord);
            vec4 b = texSample2D(g_Texture1, v_TexCoord);
            vec4 composed = mix(a, b, b.a);
            gl_FragColor = vec4(composed.rgb * g_Color.rgb, composed.a * g_Color.a);
        }
        """
        return WPEShaderProgram(
            name: shaderName,
            vertexSource: shaderPrelude(comboValues: combos, stage: .vertex) + vertex,
            fragmentSource: shaderPrelude(comboValues: combos, stage: .fragment) + fragment.replacingOccurrences(
                of: "gl_FragColor",
                with: "out_FragColor"
            ),
            isBuiltin: true
        )
    }

    private func copyProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;

        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """
        let fragment = """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;

        void main() {
            gl_FragColor = texSample2D(g_Texture0, v_TexCoord);
        }
        """
        return WPEShaderProgram(
            name: shaderName,
            vertexSource: shaderPrelude(comboValues: combos, stage: .vertex) + vertex,
            fragmentSource: shaderPrelude(comboValues: combos, stage: .fragment) + fragment.replacingOccurrences(
                of: "gl_FragColor",
                with: "out_FragColor"
            ),
            isBuiltin: true
        )
    }

    private func solidColorProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
        let vertex = """
        attribute vec3 a_Position;

        void main() {
            gl_Position = vec4(a_Position, 1.0);
        }
        """
        let fragment = """
        uniform vec4 g_Color;

        void main() {
            gl_FragColor = g_Color;
        }
        """
        return WPEShaderProgram(
            name: shaderName,
            vertexSource: shaderPrelude(comboValues: combos, stage: .vertex) + vertex,
            fragmentSource: shaderPrelude(comboValues: combos, stage: .fragment) + fragment.replacingOccurrences(
                of: "gl_FragColor",
                with: "out_FragColor"
            ),
            isBuiltin: true
        )
    }

    private func readShaderSource(path: String, shaderName: String, stage: String) throws -> String {
        let url: URL
        do {
            url = try resolveExistingFileURL(relativePath: path)
        } catch {
            throw WPERenderPipelineError.shaderMissing(name: shaderName, stage: stage, path: path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WPERenderPipelineError.shaderMissing(name: shaderName, stage: stage, path: path)
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw WPERenderPipelineError.invalidSourceEncoding(path: path)
        }
        return source
    }

    private func preprocess(
        source: String,
        logicalPath: String,
        stage: WPEShaderStage,
        comboValues: [String: Int],
        includeStack: [String]
    ) throws -> String {
        let expanded = try expandIncludes(
            in: source,
            logicalPath: logicalPath,
            includeStack: includeStack
        )
        let requiredRemoved = commentRequireDirectives(in: expanded)
        let stageSource = stage == .fragment
            ? requiredRemoved.replacingOccurrences(of: "gl_FragColor", with: "out_FragColor")
            : requiredRemoved
        return shaderPrelude(comboValues: comboValues, stage: stage) + stageSource
    }

    private func expandIncludes(
        in source: String,
        logicalPath: String,
        includeStack: [String]
    ) throws -> String {
        var output: [String] = []
        for line in source.components(separatedBy: .newlines) {
            guard let includePath = parseIncludePath(from: line) else {
                output.append(line)
                continue
            }
            output.append(try includeSource(
                includePath,
                requestedBy: logicalPath,
                includeStack: includeStack
            ))
        }
        return output.joined(separator: "\n")
    }

    private func includeSource(
        _ includePath: String,
        requestedBy: String,
        includeStack: [String]
    ) throws -> String {
        if includeStack.contains(includePath) {
            throw WPERenderPipelineError.includeCycle(path: includePath)
        }
        if let builtin = builtinInclude(named: includePath) {
            return builtin
        }

        let localPath = localIncludePath(includePath, requestedBy: requestedBy)
        let rootPath = "shaders/\(includePath)"
        let resolvedPath: String
        if (try? resolveExistingFileURL(relativePath: localPath)) != nil {
            resolvedPath = localPath
        } else if (try? resolveExistingFileURL(relativePath: rootPath)) != nil {
            resolvedPath = rootPath
        } else {
            throw WPERenderPipelineError.includeMissing(path: includePath, requestedBy: requestedBy)
        }

        let source = try readRawUTF8(path: resolvedPath)
        return try expandIncludes(
            in: source,
            logicalPath: resolvedPath,
            includeStack: includeStack + [includePath]
        )
    }

    private func readRawUTF8(path: String) throws -> String {
        let url = try resolveExistingFileURL(relativePath: path)
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw WPERenderPipelineError.invalidSourceEncoding(path: path)
        }
        return source
    }

    private func localIncludePath(_ includePath: String, requestedBy: String) -> String {
        let directory = (requestedBy as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return includePath }
        return "\(directory)/\(includePath)"
    }

    private func parseIncludePath(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#include") else { return nil }
        guard let start = trimmed.firstIndex(where: { $0 == "\"" || $0 == "<" }) else { return nil }
        let closing: Character = trimmed[start] == "\"" ? "\"" : ">"
        let contentStart = trimmed.index(after: start)
        guard let end = trimmed[contentStart...].firstIndex(of: closing) else { return nil }
        let path = String(trimmed[contentStart..<end])
        return path.isEmpty ? nil : path
    }

    private func shaderMetadata(from sources: [String], pass: WPERenderPass) -> WPEShaderMetadata {
        var comboValues: [String: Int] = [:]
        var defaultTextures: [Int: WPETextureReference] = [:]
        var uniformDefaults: [String: WPESceneShaderConstantValue] = [:]
        var materialUniformNames: [String: String] = [:]

        for source in sources {
            for line in source.components(separatedBy: .newlines) {
                if let payload = comboPayload(from: line),
                   let data = payload.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let combo = dict["combo"] as? String,
                   !combo.isEmpty,
                   let value = parseInt(dict["default"]) {
                    comboValues[combo] = value
                    continue
                }

                guard let uniform = uniformAnnotation(from: line) else {
                    continue
                }
                if uniform.type == "sampler2D" || uniform.type == "sampler2DComparison" {
                    applySamplerAnnotation(
                        uniform,
                        pass: pass,
                        defaultTextures: &defaultTextures,
                        comboValues: &comboValues
                    )
                } else if let value = parseShaderConstant(uniform.metadata["default"], type: uniform.type) {
                    uniformDefaults[uniform.name] = value
                    if let material = uniform.metadata["material"] as? String, !material.isEmpty {
                        materialUniformNames[material] = uniform.name
                    }
                }
            }
        }

        for (key, value) in pass.combos {
            comboValues[key] = value
        }

        var uniformValues = uniformDefaults
        for (key, value) in pass.constants {
            let uniformName = materialUniformNames[key] ?? key
            uniformValues[uniformName] = value
        }

        return WPEShaderMetadata(
            defaultTextures: defaultTextures,
            comboValues: comboValues,
            uniformValues: uniformValues
        )
    }

    private func applySamplerAnnotation(
        _ uniform: WPEShaderUniformAnnotation,
        pass: WPERenderPass,
        defaultTextures: inout [Int: WPETextureReference],
        comboValues: inout [String: Int]
    ) {
        guard let index = textureIndex(from: uniform.name) else {
            return
        }
        if let defaultTexture = uniform.metadata["default"] as? String, !defaultTexture.isEmpty {
            defaultTextures[index] = textureReference(defaultTexture)
        }
        guard let combo = uniform.metadata["combo"] as? String, !combo.isEmpty else {
            return
        }
        if pass.textures[index] != nil || pass.binds[index] != nil {
            comboValues[combo] = comboValues[combo] ?? 1
        } else if let defaultValue = parseInt(uniform.metadata["default"]) {
            comboValues[combo] = comboValues[combo] ?? defaultValue
        }
    }

    private func uniformAnnotation(from line: String) -> WPEShaderUniformAnnotation? {
        guard let semicolon = line.firstIndex(of: ";"),
              let commentStart = line[semicolon...].range(of: "//")?.lowerBound else {
            return nil
        }
        let declaration = line[..<semicolon].trimmingCharacters(in: .whitespaces)
        guard declaration.hasPrefix("uniform ") else {
            return nil
        }
        let parts = declaration.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 3 else {
            return nil
        }
        let type = parts[parts.count - 2]
        let rawName = parts[parts.count - 1]
        let name = rawName.split(separator: "[").first.map(String.init) ?? rawName

        let comment = String(line[line.index(commentStart, offsetBy: 2)...])
        guard let payload = jsonPayload(from: comment),
              let data = payload.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return WPEShaderUniformAnnotation(type: type, name: name, metadata: dict)
    }

    private func comboPayload(from line: String) -> String? {
        guard line.contains("[COMBO]"),
              let start = line.firstIndex(of: "{"),
              let end = line.lastIndex(of: "}") else {
            return nil
        }
        return String(line[start...end])
    }

    private func jsonPayload(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[start...end])
    }

    private func parseInt(_ raw: Any?) -> Int? {
        WPEValueParser.int(raw, boolAsNumber: true)
    }

    private func parseDouble(_ raw: Any?) -> Double? {
        WPEValueParser.double(raw, boolAsNumber: true)
    }

    private func parseShaderConstant(_ raw: Any?, type: String) -> WPESceneShaderConstantValue? {
        if let bool = raw as? Bool {
            return .bool(bool)
        }
        switch type {
        case "vec2", "vec3", "vec4":
            return parseNumberVector(raw).map(WPESceneShaderConstantValue.vector)
        case "int", "float":
            return parseDouble(raw).map(WPESceneShaderConstantValue.number)
        default:
            if let vector = parseNumberVector(raw) {
                return .vector(vector)
            }
            if let number = parseDouble(raw) {
                return .number(number)
            }
            if let string = raw as? String {
                return .string(string)
            }
            return nil
        }
    }

    private func parseNumberVector(_ raw: Any?) -> [Double]? {
        WPEValueParser.numberVector(raw, boolAsNumber: true)
    }

    private func textureBindings(
        for pass: WPERenderPass,
        defaults: [Int: WPETextureReference]
    ) -> [Int: WPETextureReference] {
        var result = defaults
        let isCommand: Bool

        switch pass.phase {
        case .command:
            isCommand = true
            result[0] = pass.textures[0] ?? pass.source
        case .material, .effect:
            isCommand = false
            result[0] = pass.source
        }

        for (index, texture) in pass.textures where index != 0 || isCommand {
            result[index] = texture
        }
        for (index, bind) in pass.binds {
            result[index] = bind == .previous ? pass.source : bind
        }
        return result
    }

    private func textureReference(_ name: String) -> WPETextureReference {
        if name == "previous" {
            return .previous
        }
        // Mirrors WPERenderGraphBuilder.textureReference(_:ownerPath:): any
        // `_`-prefixed name is a runtime FBO declared in effect.json fbos[],
        // not an on-disk asset.
        if name.hasPrefix("_") {
            return .fbo(name)
        }
        return .asset(name)
    }

    private func textureIndex(from name: String) -> Int? {
        let prefix = "g_Texture"
        guard name.hasPrefix(prefix) else {
            return nil
        }
        let suffix = name.dropFirst(prefix.count).prefix(while: \.isNumber)
        return suffix.isEmpty ? nil : Int(suffix)
    }

    private func commentRequireDirectives(in source: String) -> String {
        source.components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("#require")
                    ? "// disabled WPE require directive"
                    : line
            }
            .joined(separator: "\n")
    }

    private func shaderPrelude(comboValues: [String: Int], stage: WPEShaderStage) -> String {
        // GLSL math-constant macros that WPE workshop shaders rely on.
        // Neither GLSL nor Metal expose them as identifiers, so we replace
        // them at the preprocessor stage before transpilation runs. Values
        // match `<math.h>` to keep parity with desktop WPE builds.
        //
        // `atan2` is intentionally NOT redefined: the previous `#define atan2
        // atan` collapsed two-argument calls to Metal's single-argument
        // `atan`, breaking every workshop shader that uses polar coordinates.
        // Metal has a native `atan2(y, x)` that the transpilation pipeline
        // passes through unchanged, so the macro is unnecessary.
        var lines = [
            "// LiveWallpaper WPE shader prelude",
            "#define GLSL 1",
            "#define wpe_common_included 1",
            "#define mul(x, y) ((y) * (x))",
            "#define lerp mix",
            "#define frac fract",
            "#define saturate(x) (clamp((x), 0.0, 1.0))",
            "#define texSample2D texture",
            "#define texSample2DLod textureLod",
            "#define texture2D texture",
            "#define ddx dFdx",
            "#define ddy dFdy",
            "#define fmod(x, y) ((x) - (y) * trunc((x) / (y)))",
            "#define CAST2(x) (vec2(x))",
            "#define CAST3(x) (vec3(x))",
            "#define CAST4(x) (vec4(x))",
            "#define CAST3X3(x) (mat3(x))",
            "#ifndef M_PI",
            "#define M_PI 3.14159265358979323846",
            "#endif",
            "#ifndef M_PI_2",
            "#define M_PI_2 1.57079632679489661923",
            "#endif",
            "#ifndef M_PI_4",
            "#define M_PI_4 0.78539816339744830962",
            "#endif",
            "#ifndef M_E",
            "#define M_E 2.71828182845904523536",
            "#endif"
        ]
        switch stage {
        case .vertex:
            lines.append("#define attribute in")
            lines.append("#define varying out")
        case .fragment:
            lines.append("out vec4 out_FragColor;")
            lines.append("#define varying in")
        }
        for key in comboValues.keys.sorted() {
            guard let value = comboValues[key] else { continue }
            lines.append("#define \(key) \(value)")
            let uppercase = key.uppercased()
            if uppercase != key {
                lines.append("#define \(uppercase) \(value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func builtinInclude(named name: String) -> String? {
        switch name {
        case "common.h":
            // Phase 1.5: Add minimal WPE-runtime helpers our transpiler
            // could not synthesise. `mod(x, y)` is a GLSL intrinsic Metal
            // doesn't ship at global scope — corpus shader
            // `ps2_startup_screen` invokes it directly. `rotateVec2` is a
            // WPE-runtime helper several effects (cloudmotion, swing,
            // lens_flare) call without defining locally. Both are
            // implemented as constexpr-friendly inline functions so the
            // GLSL preprocessor + Metal compiler can fold uses at the
            // call site without losing precision.
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_H
            #define LIVEWALLPAPER_WPE_COMMON_H
            #define wpe_common_included 1
            #ifndef texSample2D
            #define texSample2D texture
            #endif
            #ifndef mod
            #define mod(x, y) ((x) - (y) * floor((x) / (y)))
            #endif

            vec2 rotateVec2(vec2 v, float angle) {
                float c = cos(angle);
                float s = sin(angle);
                return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
            }

            vec3 rotateVec3AroundAxis(vec3 v, vec3 axis, float angle) {
                float c = cos(angle);
                float s = sin(angle);
                return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
            }
            #endif
            """
        case "common_blur.h":
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_BLUR_H
            #define LIVEWALLPAPER_WPE_COMMON_BLUR_H
            #define wpe_common_blur_included 1
            #endif
            """
        case "common_blending.h":
            // Clean-room ApplyBlending implementation. WPE's reference selects
            // by compile-time `#if BLENDMODE == N`; we use a runtime switch so
            // the constant-folded result is the same for shaders that bake
            // the mode in. Mode numbers follow the Photoshop ordering common
            // to corpus shaders; unknown modes fall back to the source colour
            // alpha-blended in (Capability: Degraded — exact mode parity is
            // Phase 5 work).
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_BLENDING_H
            #define LIVEWALLPAPER_WPE_COMMON_BLENDING_H
            #define wpe_common_blending_included 1

            // Named blend-mode constants WPE workshop shaders pass to
            // ApplyBlending. Values match Photoshop ordering and our
            // implementation's runtime switch below. Workshops invoke
            // ApplyBlending(BlendLinearDodge, A, B, opacity) — without
            // these the transpiler emits 'undeclared identifier
            // BlendLinearDodge' for the corpus vhs / sine_wave_circle
            // shaders.
            #define BlendNormal 0
            #define BlendDarken 2
            #define BlendLighten 3
            #define BlendMultiply 4
            #define BlendScreen 5
            #define BlendLinearDodge 6
            #define BlendAdd 6
            #define BlendSubtract 7
            #define BlendDifference 8

            // No `in` qualifier on parameters — it's GLSL-default (and thus
            // optional) but the MSL backend rejects it as an unknown type
            // name when the transpiler forwards this header verbatim.
            vec3 ApplyBlending(int blendMode, vec3 A, vec3 B, float opacity) {
                vec3 result = B;
                if (blendMode == 2)      { result = min(A, B); }                                     // Darken
                else if (blendMode == 3) { result = max(A, B); }                                     // Lighten
                else if (blendMode == 4) { result = A * B; }                                          // Multiply
                else if (blendMode == 5) { result = vec3(1.0) - (vec3(1.0) - A) * (vec3(1.0) - B); } // Screen
                else if (blendMode == 6) { result = A + B; }                                          // LinearDodge / Add
                else if (blendMode == 7) { result = max(vec3(0.0), A - B); }                         // Subtract
                else if (blendMode == 8) { result = vec3(1.0) - abs(vec3(1.0) - B - A); }            // Difference
                return mix(A, result, opacity);
            }

            float ApplyBlendingAlpha(int blendMode, float a, float b, float opacity) {
                // Most blend modes leave alpha unmodified; the source alpha
                // gates how much of the blended colour shows through. The
                // `blendMode` argument is accepted but currently ignored — a
                // mode-specific alpha policy is Phase 5 work.
                return mix(a, max(a, b), opacity);
            }
            #endif
            """
        case "common_composite.h":
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_COMPOSITE_H
            #define LIVEWALLPAPER_WPE_COMMON_COMPOSITE_H
            #define wpe_common_composite_included 1
            #ifndef COMPOSITE
            #define COMPOSITE 0
            #endif

            vec2 ApplyCompositeOffset(vec2 coord, vec2 resolution) {
                return coord;
            }

            vec4 ApplyComposite(vec4 baseColor, vec4 compositeColor) {
            #if COMPOSITE == 1
                return mix(baseColor, compositeColor, compositeColor.a);
            #elif COMPOSITE == 2
                return mix(compositeColor, baseColor, baseColor.a);
            #elif COMPOSITE == 3
                return vec4(compositeColor.rgb, compositeColor.a * (1.0 - baseColor.a));
            #else
                return compositeColor;
            #endif
            }
            #endif
            """
        case "common_perspective.h":
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_PERSPECTIVE_H
            #define LIVEWALLPAPER_WPE_COMMON_PERSPECTIVE_H
            #define wpe_common_perspective_included 1
            #endif
            """
        default:
            return nil
        }
    }

    private func resolveExistingFileURL(relativePath: String) throws -> URL {
        // Map the resolver's `ResolveError` into the pipeline-builder's
        // `WPERenderPipelineError.includeMissing` so existing call sites
        // (and tests asserting `throws: WPERenderPipelineError.self`) keep
        // their error contract while still picking up the engine-root
        // fall-through.
        do {
            return try resolver.resolveExistingFileURL(relativePath: relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing,
                SceneResourceResolver.ResolveError.pathEscape {
            throw WPERenderPipelineError.includeMissing(path: relativePath, requestedBy: "")
        }
    }
}
#endif
