#if !LITE_BUILD
import Foundation

private func isImplicitFBOTextureName(_ name: String) -> Bool {
    name.hasPrefix("_") && !name.hasPrefix("__")
}

struct WPERenderPipelineBuilder: Sendable {
    private let resolver: WPEMultiRootResourceResolver
    private let shaderLoader: WPEShaderSourceLoader

    init(
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
        self.shaderLoader = WPEShaderSourceLoader(
            cacheRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    init(
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryProvider: primaryProvider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
        self.shaderLoader = WPEShaderSourceLoader(
            primaryProvider: primaryProvider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    func build(graph: WPERenderGraph) throws -> WPEPreparedRenderPipeline {
        let layers = try graph.layers.map { layer in
            let passes = try layer.passes.map { pass in
                try preparedPass(for: pass)
            }
            return WPEPreparedRenderLayer(
                graphLayer: layer,
                puppetModel: try loadPuppetModel(for: layer),
                passes: passes
            )
        }
        return WPEPreparedRenderPipeline(layers: layers)
    }

    private func loadPuppetModel(for layer: WPERenderLayer) throws -> WPEPuppetModel? {
        guard let puppetPath = layer.puppetPath else { return nil }
        let model: WPEPuppetModel
        do {
            let data = try resolver.data(relativePath: puppetPath)
            model = try WPEMdlParser.parse(data: data)
        } catch {
            // Missing / corrupt .mdl → degrade to the flat material image.
            return nil
        }
        if (layer.imagePath as NSString).pathExtension.lowercased() == "mdl" {
            return model
        }
        // MDLV0021/0023 ship vertices pre-assembled in object space. MDLV0019/0020 store the
        // flat character-sheet (bind pose = exploded pieces); the assembled pose is recovered by
        // linear-blend skinning through the MDLA animation pose (see the executor's skinning gate).
        // Generations below 19 are unverified, so still refused.
        guard model.version >= 19 else {
            let generation = String(format: "MDLV%04d", model.version)
            Logger.warning(
                "WPE scene uses unsupported puppet generation \(generation) "
                    + "('\(puppetPath)'); refusing to render to avoid a misaligned wallpaper.",
                category: .wpeRender
            )
            throw SceneRenderingError.metalRendererUnsupported(
                reason: "this wallpaper uses the legacy \(generation) puppet format, "
                    + "which this renderer cannot assemble correctly"
            )
        }
        return model
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

    init(
        cacheRootURL: URL,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    init(
        primaryProvider: any WPESceneAssetProvider,
        dependencyMounts: [WPEAssetMount] = [],
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryProvider: primaryProvider,
            dependencyMounts: dependencyMounts,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
        )
    }

    func load(shaderName: String, pass: WPERenderPass) throws -> WPEShaderLoadResult {
        if shouldPreferSceneSource(shaderName: shaderName) {
            do {
                return try sourceProgram(shaderName: shaderName, pass: pass)
            } catch WPERenderPipelineError.shaderMissing {
                // Some corpus effects are satisfied only by Metal-side built-ins.
                // Fall back to the copy program when the workshop ships no source,
                // but only on shaderMissing so invalid source/include errors surface.
            }
        }

        if let builtin = builtinProgram(shaderName: shaderName, combos: pass.combos) {
            return WPEShaderLoadResult(
                program: builtin,
                textureBindings: textureBindings(for: pass, defaults: [:]),
                comboValues: pass.combos,
                uniformValues: pass.constants
            )
        }

        return try sourceProgram(shaderName: shaderName, pass: pass)
    }

    private func shouldPreferSceneSource(shaderName: String) -> Bool {
        WPEBuiltinShaderName.normalized(shaderName).hasPrefix("effect_")
    }

    private func sourceProgram(shaderName: String, pass: WPERenderPass) throws -> WPEShaderLoadResult {
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
            if normalized.hasPrefix("effect_") {
                return copyProgram(shaderName: shaderName, combos: combos)
            }
            guard normalized == "genericimage2"
                || normalized == "genericimage4"
                || WPEBuiltinShaderName.isGenericImageShader(shaderName) else {
                return nil
            }
            return genericImageProgram(shaderName: shaderName, combos: combos)
        }
    }

    /// WPE's `genericimage*` family with the SPRITESHEET combo on: the
    /// vertex shader derives UVs from `g_Texture0Translation` (current
    /// frame) plus `g_Texture0TranslationNext` (next frame), both sharing
    /// the `g_Texture0Rotation` per-frame UV transform. The fragment
    /// samples both and mixes by `g_SpriteFrameBlend` (0..1) so a 3-frame
    /// strip animates as a smooth crossfade instead of a 25Hz strobe —
    /// matches WPE's `common_particles.h` `ComputeSpriteFrame` pattern.
    /// Without the combo, fall back to the trivial copy program.
    private func genericImageProgram(shaderName: String, combos: [String: Int]) -> WPEShaderProgram {
        let usesSpriteSheet = combos.contains { key, value in
            key.uppercased() == "SPRITESHEET" && value != 0
        }
        guard usesSpriteSheet else {
            return copyProgram(shaderName: shaderName, combos: combos)
        }

        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform vec2 g_Texture0Translation;
        uniform vec2 g_Texture0TranslationNext;
        uniform vec4 g_Texture0Rotation;
        varying vec2 v_TexCoord;
        varying vec2 v_TexCoordNext;

        void main() {
            gl_Position = vec4(a_Position, 1.0);
            vec2 frameBasis = a_TexCoord.x * g_Texture0Rotation.xy
                + a_TexCoord.y * g_Texture0Rotation.zw;
            v_TexCoord     = g_Texture0Translation     + frameBasis;
            v_TexCoordNext = g_Texture0TranslationNext + frameBasis;
        }
        """
        let fragment = """
        uniform sampler2D g_Texture0;
        uniform float g_SpriteFrameBlend;
        varying vec2 v_TexCoord;
        varying vec2 v_TexCoordNext;

        void main() {
            vec4 a = texSample2D(g_Texture0, v_TexCoord);
            vec4 b = texSample2D(g_Texture0, v_TexCoordNext);
            gl_FragColor = mix(a, b, g_SpriteFrameBlend);
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
        let data: Data
        do {
            data = try resolver.data(relativePath: path)
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
        let macroNeutralized = stripPreludeMacroRedefines(in: requiredRemoved)
        let implicitDefines = implicitConditionalDefines(
            in: macroNeutralized,
            knownCombos: comboValues
        )
        let stageSource = stage == .fragment
            ? macroNeutralized.replacingOccurrences(of: "gl_FragColor", with: "out_FragColor")
            : macroNeutralized
        return shaderPrelude(comboValues: comboValues, stage: stage)
            + implicitDefines
            + stageSource
    }

    // WPE's runtime treats an undefined combo as `0` inside `#if/#elif`
    // expressions; strict shader preprocessors raise "unexpected token
    // after conditional expression" for an unknown identifier. Scan the
    // expanded source for uppercase identifiers referenced in preprocessor
    // conditionals and emit `#define X 0` for any that the prelude / combo
    // values / shader body itself hasn't already defined.
    private func implicitConditionalDefines(
        in source: String,
        knownCombos: [String: Int]
    ) -> String {
        let referenced = Self.collectConditionalIdentifiers(in: source)
        guard !referenced.isEmpty else { return "" }

        var knownComboNames = Set<String>()
        for key in knownCombos.keys {
            knownComboNames.insert(key)
            knownComboNames.insert(key.uppercased())
        }

        let existing = Self.collectDefinedMacroNames(in: source)
            .union(knownComboNames)
            .union(Self.preludeReservedMacros)
            .union(Self.builtinPreprocessorTokens)

        let missing = referenced.subtracting(existing).sorted()
        guard !missing.isEmpty else { return "" }

        return missing
            .map { "#define \($0) 0" }
            .joined(separator: "\n") + "\n"
    }

    private static func collectDefinedMacroNames(in source: String) -> Set<String> {
        var defines: Set<String> = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#define") else { continue }
            let after = trimmed.dropFirst("#define".count)
                .drop(while: { $0 == " " || $0 == "\t" })
            let name = after.prefix(while: {
                $0.isLetter || $0.isNumber || $0 == "_"
            })
            if !name.isEmpty {
                defines.insert(String(name))
            }
        }
        return defines
    }

    private static func collectConditionalIdentifiers(in source: String) -> Set<String> {
        var refs: Set<String> = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let directive = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            let head = directive.prefix(while: { $0.isLetter })
            // Only `#if` and `#elif` evaluate the operand as an integer
            // expression, so they're the only ones that need missing
            // identifiers to be `#define`d to 0. `#ifdef` / `#ifndef`
            // only check whether the name is defined — auto-defining
            // would flip those branches.
            guard head == "if" || head == "elif" else { continue }
            let expression = Self.stripDefinedOperator(in: String(directive))
            refs.formUnion(Self.uppercaseIdentifiers(in: expression))
        }
        return refs
    }

    // Identifiers inside `defined(X)` / `defined X` are existence checks, not
    // value reads, so strip them before scanning for identifiers to auto-define.
    private static func stripDefinedOperator(in expression: String) -> String {
        var result = expression
        result = result.replacingOccurrences(
            of: #"defined\s*\(\s*[A-Za-z_]\w*\s*\)"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"defined\s+[A-Za-z_]\w*"#,
            with: " ",
            options: .regularExpression
        )
        return result
    }

    private static func uppercaseIdentifiers(in expression: String) -> Set<String> {
        var result: Set<String> = []
        var current = ""
        let chars = Array(expression)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else {
                if Self.isUppercaseMacroToken(current) {
                    result.insert(current)
                }
                current = ""
            }
            index += 1
        }
        if Self.isUppercaseMacroToken(current) {
            result.insert(current)
        }
        return result
    }

    private static func isUppercaseMacroToken(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        guard let first = token.first, first.isLetter || first == "_" else { return false }
        for ch in token {
            if ch.isLowercase { return false }
        }
        return true
    }

    private static let builtinPreprocessorTokens: Set<String> = [
        "defined", "GLSL", "GL_ES", "VERSION", "__VERSION__", "GL_FRAGMENT_PRECISION_HIGH"
    ]

    // GLSL ES 3.00 treats `#define X A` after `#define X B` as a hard
    // error when the token sequences differ. Our prelude already defines
    // these compat symbols (HLSL aliases + math constants); workshop
    // shaders frequently restate them with different precision (e.g.
    // `M_PI` to 32 digits vs our 20) which the compiler rejects even
    // though both collapse to the same single-precision float. Strip the
    // user-side redefines and let the prelude win.
    private func stripPreludeMacroRedefines(in source: String) -> String {
        let neutralized = source.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#define") else { return line }
            let afterDefine = trimmed.dropFirst("#define".count)
                .drop(while: { $0 == " " || $0 == "\t" })
            let macroName = afterDefine.prefix(while: {
                $0.isLetter || $0.isNumber || $0 == "_"
            })
            guard !macroName.isEmpty else { return line }
            guard Self.preludeReservedMacros.contains(String(macroName)) else {
                return line
            }
            return "// disabled redefine of prelude macro: \(macroName)"
        }
        return neutralized.joined(separator: "\n")
    }

    private static let preludeReservedMacros: Set<String> = [
        "M_PI", "M_PI_2", "M_PI_4", "M_E",
        "mul", "lerp", "frac", "saturate",
        "texSample2D", "texSample2DLod", "texture2D",
        "ddx", "ddy", "fmod",
        "CAST2", "CAST3", "CAST4", "CAST2X2", "CAST3X3", "CAST4X4"
    ]

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
        if resolver.exists(relativePath: localPath) {
            resolvedPath = localPath
        } else if resolver.exists(relativePath: rootPath) {
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
        let data: Data
        do {
            data = try resolver.data(relativePath: path)
        } catch {
            throw WPERenderPipelineError.includeMissing(path: path, requestedBy: "")
        }
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
        var samplerUniforms: [WPEShaderUniformAnnotation] = []

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
                    samplerUniforms.append(uniform)
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

        for uniform in samplerUniforms where requireConditionsSatisfied(uniform.metadata["require"], comboValues: comboValues) {
            applySamplerAnnotation(
                uniform,
                pass: pass,
                defaultTextures: &defaultTextures,
                comboValues: &comboValues
            )
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

    private func requireConditionsSatisfied(_ raw: Any?, comboValues: [String: Int]) -> Bool {
        guard let requirements = raw as? [String: Any], !requirements.isEmpty else {
            return true
        }
        for (key, rawValue) in requirements {
            guard let required = parseInt(rawValue) else {
                return false
            }
            if (comboValues[key] ?? 0) != required {
                return false
            }
        }
        return true
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
        if let bool = WPEValueParser.strictBool(raw) {
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
        // shake/pulse slot 2 is the per-instance OPACITY mask (multiplies the
        // effect's strength). When the scene doesn't declare one it must
        // default to WHITE (= full effect everywhere) — a black/unbound slot
        // silently disables the effect (oracle: 3554161528 cloud bands froze).
        if usesWhiteOpacityMaskDefault(for: pass),
           !pass.textures.keys.contains(2), !pass.binds.keys.contains(2) {
            result[2] = .asset("util/white")
        }
        return result
    }

    private func usesWhiteOpacityMaskDefault(for pass: WPERenderPass) -> Bool {
        guard case .effect = pass.phase else { return false }
        let shader = pass.shader.lowercased()
        return shader.contains("effects/shake") || shader.contains("effects/pulse")
    }

    private func textureReference(_ name: String) -> WPETextureReference {
        if name == "previous" {
            return .previous
        }
        if isImplicitFBOTextureName(name) {
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
        // Builtin WPE macros (CAST2/ddx/ddy/saturate/…) live in `WPEShaderBuiltinMacros`
        // so the GPU MSDF text path resolves the exact same intrinsics.
        var lines = ["// LiveWallpaper WPE shader prelude"]
        lines.append(contentsOf: WPEShaderBuiltinMacros.glslPreludeLines)
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

            // WPE common normal-map decompressor. Workshop normal effects
            // pack `xy` into the lo bits and reconstruct `z` from the
            // length constraint; this matches the standard tangent-space
            // unpack used in `effects/refract.frag` and `effects/lightshafts.frag`.
            vec3 DecompressNormal(vec4 packed) {
                vec2 nxy = packed.xy * 2.0 - 1.0;
                float nz = sqrt(max(0.0, 1.0 - dot(nxy, nxy)));
                return vec3(nxy, nz);
            }

            vec3 DecompressNormal(vec3 packed) {
                return DecompressNormal(vec4(packed, 0.0));
            }
            #endif
            """
        case "common_blur.h":
            // Stock WPE `blur*a` separable-Gaussian helpers. Weights match the
            // Sigg/Hadwiger 2005 formulation `blur_precise_gaussian.frag` expects.
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_BLUR_H
            #define LIVEWALLPAPER_WPE_COMMON_BLUR_H
            #define wpe_common_blur_included 1

            // g_Texture0 is declared by the including shader (every WPE
            // blur pass binds previous-frame at slot 0). Declaring it
            // here too would trip GLSL ES 3.00 single-scope
            // redeclaration rules.

            vec4 blur13a(vec2 uv, vec2 direction) {
                vec4 color = texSample2D(g_Texture0, uv) * 0.1964825501511404;
                color += texSample2D(g_Texture0, uv + direction * 1.411764705882353) * 0.2969069646728344;
                color += texSample2D(g_Texture0, uv - direction * 1.411764705882353) * 0.2969069646728344;
                color += texSample2D(g_Texture0, uv + direction * 3.2941176470588234) * 0.09447039785044732;
                color += texSample2D(g_Texture0, uv - direction * 3.2941176470588234) * 0.09447039785044732;
                color += texSample2D(g_Texture0, uv + direction * 5.176470588235294) * 0.010381362401148057;
                color += texSample2D(g_Texture0, uv - direction * 5.176470588235294) * 0.010381362401148057;
                return color;
            }

            vec4 blur7a(vec2 uv, vec2 direction) {
                vec4 color = texSample2D(g_Texture0, uv) * 0.3829;
                color += texSample2D(g_Texture0, uv + direction * 1.3846153846) * 0.30857;
                color += texSample2D(g_Texture0, uv - direction * 1.3846153846) * 0.30857;
                return color;
            }

            vec4 blur3a(vec2 uv, vec2 direction) {
                vec4 color = texSample2D(g_Texture0, uv) * 0.5;
                color += texSample2D(g_Texture0, uv + direction) * 0.25;
                color += texSample2D(g_Texture0, uv - direction) * 0.25;
                return color;
            }

            vec2 blurRotateVec2(vec2 v, float r) {
                vec2 cs = vec2(cos(r), sin(r));
                return vec2(v.x * cs.x - v.y * cs.y, v.x * cs.y + v.y * cs.x);
            }

            vec4 blurRadial13a(vec2 uv, vec2 center, float amount) {
                vec2 delta = uv - center;
                amount = amount * 0.025;
                float o1 = 1.4091998770852122 * amount;
                float o2 = 3.2979348079914822 * amount;
                float o3 = 5.2062900776825969 * amount;
                vec2 r1 = blurRotateVec2(delta, o1) - delta;
                vec2 r2 = blurRotateVec2(delta, o2) - delta;
                vec2 r3 = blurRotateVec2(delta, o3) - delta;
                return texSample2D(g_Texture0, uv) * 0.1976406528809576
                    + texSample2D(g_Texture0, center + r1 + delta) * 0.2959855056006557
                    + texSample2D(g_Texture0, center - r1 + delta) * 0.2959855056006557
                    + texSample2D(g_Texture0, center + r2 + delta) * 0.0935333619980593
                    + texSample2D(g_Texture0, center - r2 + delta) * 0.0935333619980593
                    + texSample2D(g_Texture0, center + r3 + delta) * 0.0116608059608062
                    + texSample2D(g_Texture0, center - r3 + delta) * 0.0116608059608062;
            }

            vec4 blurRadial7a(vec2 uv, vec2 center, float amount) {
                vec2 delta = uv - center;
                amount = amount * 0.025;
                float o1 = 2.3515644035337887 * amount;
                float o2 = 0.469433779698372 * amount;
                float o3 = 1.4091998770852121 * amount;
                float o4 = 3.0 * amount;
                vec2 r1 = blurRotateVec2(delta, o1) - delta;
                vec2 r2 = blurRotateVec2(delta, o2) - delta;
                vec2 r3 = blurRotateVec2(delta, -o3) - delta;
                vec2 r4 = blurRotateVec2(delta, -o4) - delta;
                return texSample2D(g_Texture0, center + r1 + delta) * 0.2028175528299753
                    + texSample2D(g_Texture0, center + r2 + delta) * 0.4044856614512112
                    + texSample2D(g_Texture0, center + r3 + delta) * 0.3213933537319605
                    + texSample2D(g_Texture0, center + r4 + delta) * 0.0713034319868530;
            }

            vec4 blurRadial3a(vec2 uv, vec2 center, float amount) {
                vec2 delta = uv - center;
                amount = amount * 0.025;
                vec2 r1 = blurRotateVec2(delta, amount) - delta;
                return texSample2D(g_Texture0, center + delta) * 0.5
                    + texSample2D(g_Texture0, center + r1 + delta) * 0.25
                    + texSample2D(g_Texture0, center - r1 + delta) * 0.25;
            }
            #endif
            """
        case "common_vertex.h":
            // Workshop authors `#include` this but rarely depend on its content,
            // so a guarded empty stub satisfies resolution without polluting the prelude.
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_VERTEX_H
            #define LIVEWALLPAPER_WPE_COMMON_VERTEX_H
            #define wpe_common_vertex_included 1
            #endif
            """
        case "common_fragment.h":
            // WPE 2.8 `font.frag` (+ workshop text shaders) call `ConvertSampleR8`
            // to read R8/alpha glyph coverage; an empty stub broke their translate.
            // Mirror WPE's GLSL path (`HLSL_SM30` never set in our pipeline → `.r`).
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_FRAGMENT_H
            #define LIVEWALLPAPER_WPE_COMMON_FRAGMENT_H
            #define wpe_common_fragment_included 1

            float ConvertSampleR8(vec4 _sample) {
                return _sample.r;
            }
            #endif
            """
        case "common_blending.h":
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_BLENDING_H
            #define LIVEWALLPAPER_WPE_COMMON_BLENDING_H
            #define wpe_common_blending_included 1

            // Named blend-mode constants WPE workshop shaders pass to
            // ApplyBlending. Integer values match Wallpaper Engine's
            // authoritative common_blending.h `#if BLENDMODE == N` chain
            // (NOT Photoshop ordering) — scene `combos.BLENDMODE` values are
            // emitted against this enum, so the runtime switch below must
            // agree with it. Workshops invoke ApplyBlending(BlendLinearDodge,
            // A, B, opacity); without these the transpiler emits 'undeclared
            // identifier BlendLinearDodge' for the corpus vhs / sine_wave_circle
            // shaders.
            #define BlendNormal 0
            #define BlendDarken 1
            #define BlendMultiply 2
            #define BlendSubtract 4
            #define BlendLighten 6
            #define BlendScreen 7
            #define BlendLinearDodge 9
            #define BlendAdd 9
            #define BlendDifference 18
            #define BlendWPELinearDodge 31

            // Per-channel blend helpers (mirror WPE common_blending.h macros).
            float wpe_s_colorBurn(float b, float s)  { return (s == 0.0) ? 0.0 : max(1.0 - (1.0 - b) / s, 0.0); }
            float wpe_s_colorDodge(float b, float s) { return (s == 1.0) ? 1.0 : min(b / (1.0 - s), 1.0); }
            float wpe_s_overlay(float b, float s)    { return b < 0.5 ? (2.0 * b * s) : (1.0 - 2.0 * (1.0 - b) * (1.0 - s)); }
            float wpe_s_softLight(float b, float s)  { return s < 0.5 ? (2.0 * b * s + b * b * (1.0 - 2.0 * s)) : (sqrt(b) * (2.0 * s - 1.0) + 2.0 * b * (1.0 - s)); }
            float wpe_s_linearLight(float b, float s){ return s < 0.5 ? max(b + 2.0 * s - 1.0, 0.0) : (b + 2.0 * (s - 0.5)); }
            float wpe_s_vividLight(float b, float s) { return s < 0.5 ? wpe_s_colorBurn(b, 2.0 * s) : wpe_s_colorDodge(b, 2.0 * (s - 0.5)); }
            float wpe_s_pinLight(float b, float s)   { return s < 0.5 ? min(b, 2.0 * s) : max(b, 2.0 * (s - 0.5)); }
            float wpe_s_hardMix(float b, float s)    { return wpe_s_vividLight(b, s) < 0.5 ? 0.0 : 1.0; }
            float wpe_s_reflect(float b, float s)    { return (s == 1.0) ? 1.0 : min(b * b / (1.0 - s), 1.0); }

            vec3 wpe_blend_colorBurn(vec3 b, vec3 s)  { return vec3(wpe_s_colorBurn(b.r, s.r), wpe_s_colorBurn(b.g, s.g), wpe_s_colorBurn(b.b, s.b)); }
            vec3 wpe_blend_colorDodge(vec3 b, vec3 s) { return vec3(wpe_s_colorDodge(b.r, s.r), wpe_s_colorDodge(b.g, s.g), wpe_s_colorDodge(b.b, s.b)); }
            vec3 wpe_blend_overlay(vec3 b, vec3 s)    { return vec3(wpe_s_overlay(b.r, s.r), wpe_s_overlay(b.g, s.g), wpe_s_overlay(b.b, s.b)); }
            vec3 wpe_blend_softLight(vec3 b, vec3 s)  { return vec3(wpe_s_softLight(b.r, s.r), wpe_s_softLight(b.g, s.g), wpe_s_softLight(b.b, s.b)); }
            vec3 wpe_blend_linearLight(vec3 b, vec3 s){ return vec3(wpe_s_linearLight(b.r, s.r), wpe_s_linearLight(b.g, s.g), wpe_s_linearLight(b.b, s.b)); }
            vec3 wpe_blend_vividLight(vec3 b, vec3 s) { return vec3(wpe_s_vividLight(b.r, s.r), wpe_s_vividLight(b.g, s.g), wpe_s_vividLight(b.b, s.b)); }
            vec3 wpe_blend_pinLight(vec3 b, vec3 s)   { return vec3(wpe_s_pinLight(b.r, s.r), wpe_s_pinLight(b.g, s.g), wpe_s_pinLight(b.b, s.b)); }
            vec3 wpe_blend_hardMix(vec3 b, vec3 s)    { return vec3(wpe_s_hardMix(b.r, s.r), wpe_s_hardMix(b.g, s.g), wpe_s_hardMix(b.b, s.b)); }
            vec3 wpe_blend_reflect(vec3 b, vec3 s)    { return vec3(wpe_s_reflect(b.r, s.r), wpe_s_reflect(b.g, s.g), wpe_s_reflect(b.b, s.b)); }

            // HSL conversion for the Hue/Saturation/Color/Luminosity modes
            // (verbatim from WPE common_blending.h; HDR clamp branch dropped).
            vec3 wpe_RGBToHSL(vec3 color) {
                vec3 hsl;
                float fmin = min(min(color.r, color.g), color.b);
                float fmax = max(max(color.r, color.g), color.b);
                float delta = fmax - fmin;
                hsl.z = (fmax + fmin) / 2.0;
                if (delta == 0.0) {
                    hsl.x = 0.0;
                    hsl.y = 0.0;
                } else {
                    if (hsl.z < 0.5) { hsl.y = delta / (fmax + fmin); }
                    else             { hsl.y = delta / (2.0 - fmax - fmin); }
                    float deltaR = (((fmax - color.r) / 6.0) + (delta / 2.0)) / delta;
                    float deltaG = (((fmax - color.g) / 6.0) + (delta / 2.0)) / delta;
                    float deltaB = (((fmax - color.b) / 6.0) + (delta / 2.0)) / delta;
                    if (color.r == fmax)      { hsl.x = deltaB - deltaG; }
                    else if (color.g == fmax) { hsl.x = (1.0 / 3.0) + deltaR - deltaB; }
                    else if (color.b == fmax) { hsl.x = (2.0 / 3.0) + deltaG - deltaR; }
                    if (hsl.x < 0.0)      { hsl.x += 1.0; }
                    else if (hsl.x > 1.0) { hsl.x -= 1.0; }
                }
                return hsl;
            }

            float wpe_HueToRGB(float f1, float f2, float hue) {
                if (hue < 0.0)      { hue += 1.0; }
                else if (hue > 1.0) { hue -= 1.0; }
                float res;
                if ((6.0 * hue) < 1.0)      { res = f1 + (f2 - f1) * 6.0 * hue; }
                else if ((2.0 * hue) < 1.0) { res = f2; }
                else if ((3.0 * hue) < 2.0) { res = f1 + (f2 - f1) * ((2.0 / 3.0) - hue) * 6.0; }
                else                        { res = f1; }
                return res;
            }

            vec3 wpe_HSLToRGB(vec3 hsl) {
                vec3 rgb;
                if (hsl.y == 0.0) {
                    rgb = vec3(hsl.z);
                } else {
                    float f2;
                    if (hsl.z < 0.5) { f2 = hsl.z * (1.0 + hsl.y); }
                    else             { f2 = (hsl.z + hsl.y) - (hsl.y * hsl.z); }
                    float f1 = 2.0 * hsl.z - f2;
                    rgb.r = wpe_HueToRGB(f1, f2, hsl.x + (1.0 / 3.0));
                    rgb.g = wpe_HueToRGB(f1, f2, hsl.x);
                    rgb.b = wpe_HueToRGB(f1, f2, hsl.x - (1.0 / 3.0));
                }
                return rgb;
            }

            vec3 wpe_blend_hue(vec3 base, vec3 blend)        { vec3 h = wpe_RGBToHSL(base); return wpe_HSLToRGB(vec3(wpe_RGBToHSL(blend).r, h.g, h.b)); }
            vec3 wpe_blend_saturation(vec3 base, vec3 blend) { vec3 h = wpe_RGBToHSL(base); return wpe_HSLToRGB(vec3(h.r, wpe_RGBToHSL(blend).g, h.b)); }
            vec3 wpe_blend_color(vec3 base, vec3 blend)      { vec3 bh = wpe_RGBToHSL(blend); return wpe_HSLToRGB(vec3(bh.r, bh.g, wpe_RGBToHSL(base).b)); }
            vec3 wpe_blend_luminosity(vec3 base, vec3 blend) { vec3 h = wpe_RGBToHSL(base); return wpe_HSLToRGB(vec3(h.r, h.g, wpe_RGBToHSL(blend).b)); }

            // Runtime port of WPE common_blending.h ApplyBlending. WPE selects
            // a single branch at compile time via `#if BLENDMODE == N`; we keep
            // a runtime switch keyed on the same integers so one synthesized
            // header serves every baked combo. No `in` qualifier on parameters
            // — it's GLSL-default but the MSL backend rejects it as an unknown
            // type name when the transpiler forwards this header verbatim.
            vec3 ApplyBlending(int blendMode, vec3 A, vec3 B, float opacity) {
                // Modes that ignore opacity in WPE.
                if (blendMode == 5)  { return min(A, B); }              // Darker Color
                if (blendMode == 10) { return max(A, B); }              // Lighter Color
                if (blendMode == 31) { return A + B * opacity; }        // imageblending additive (premultiplied)

                vec3 result;
                if      (blendMode == 1)  { result = min(A, B); }                                       // Darken
                else if (blendMode == 2)  { result = A * B; }                                           // Multiply
                else if (blendMode == 3)  { result = wpe_blend_colorBurn(A, B); }                       // Color Burn
                else if (blendMode == 4 || blendMode == 20) { result = max(A + B - vec3(1.0), vec3(0.0)); } // Subtract
                else if (blendMode == 6)  { result = max(A, B); }                                       // Lighten
                else if (blendMode == 7)  { result = vec3(1.0) - (vec3(1.0) - A) * (vec3(1.0) - B); }   // Screen
                else if (blendMode == 8)  { result = wpe_blend_colorDodge(A, B); }                      // Color Dodge
                else if (blendMode == 9)  { result = min(A + B, vec3(1.0)); }                           // Add (Linear Dodge)
                else if (blendMode == 11) { result = wpe_blend_overlay(A, B); }                         // Overlay
                else if (blendMode == 12) { result = wpe_blend_softLight(A, B); }                       // Soft Light
                else if (blendMode == 13) { result = wpe_blend_overlay(B, A); }                         // Hard Light
                else if (blendMode == 14) { result = wpe_blend_vividLight(A, B); }                      // Vivid Light
                else if (blendMode == 15) { result = wpe_blend_linearLight(A, B); }                     // Linear Light
                else if (blendMode == 16) { result = wpe_blend_pinLight(A, B); }                        // Pin Light
                else if (blendMode == 17) { result = wpe_blend_hardMix(A, B); }                         // Hard Mix
                else if (blendMode == 18) { result = abs(A - B); }                                      // Difference
                else if (blendMode == 19) { result = A + B - 2.0 * A * B; }                             // Exclusion
                else if (blendMode == 21) { result = wpe_blend_reflect(A, B); }                         // Reflect
                else if (blendMode == 22) { result = wpe_blend_reflect(B, A); }                         // Glow
                else if (blendMode == 23) { result = min(A, B) - max(A, B) + vec3(1.0); }               // Phoenix
                else if (blendMode == 24) { result = (A + B) * 0.5; }                                   // Average
                else if (blendMode == 25) { result = vec3(1.0) - abs(vec3(1.0) - A - B); }              // Negation
                else if (blendMode == 26) { result = wpe_blend_hue(A, B); }                             // Hue
                else if (blendMode == 27) { result = wpe_blend_saturation(A, B); }                      // Saturation
                else if (blendMode == 28) { result = wpe_blend_color(A, B); }                           // Color
                else if (blendMode == 29) { result = wpe_blend_luminosity(A, B); }                      // Luminosity
                else if (blendMode == 30) { result = vec3(max(A.x, max(A.y, A.z))) * B; }               // Tint
                else if (blendMode == 32) { result = A + A * B; }                                       // imageblending mode 32
                else                      { result = B; }                                               // Normal (0 / default)
                return mix(A, result, opacity);
            }

            vec3 ApplyBlending(int blendMode, vec3 A, vec3 B, vec3 opacity) {
                vec3 result = ApplyBlending(blendMode, A, B, 1.0);
                return mix(A, result, opacity);
            }

            float ApplyBlendingAlpha(int blendMode, float a, float b, float opacity) {
                // Most blend modes leave alpha unmodified; the source alpha
                // gates how much of the blended colour shows through. The
                // `blendMode` argument is accepted but currently ignored.
                return mix(a, max(a, b), opacity);
            }

            // `BlendOpacity(base, overlay, mode, opacity)` is the WPE
            // shader-side convenience wrapper around ApplyBlending. The
            // overlay parameter is either a vec3 colour or a scalar
            // luminance (broadcast to vec3); workshop authors use both.
            vec3 BlendOpacity(vec3 A, vec3 B, int blendMode, float opacity) {
                return ApplyBlending(blendMode, A, B, opacity);
            }

            vec3 BlendOpacity(vec3 A, float b, int blendMode, float opacity) {
                return ApplyBlending(blendMode, A, vec3(b), opacity);
            }

            // Contrast/saturation/brightness grade used by `color_grading` and
            // similar workshop effects. Mirrors common_blending.h: luminance via
            // LumCoeff, mix toward intensity for saturation, mix toward 0.5 grey
            // for contrast. Without it the transpiler emits 'undeclared
            // identifier ContrastSaturationBrightness'.
            vec3 ContrastSaturationBrightness(vec3 color, float brt, float sat, float con) {
                const vec3 LumCoeff = vec3(0.2125, 0.7154, 0.0721);
                vec3 AvgLumin = vec3(0.5);
                vec3 brtColor = color * brt;
                vec3 intensity = vec3(dot(brtColor, LumCoeff));
                vec3 satColor = mix(intensity, brtColor, sat);
                vec3 conColor = mix(AvgLumin, satColor, con);
                return conColor;
            }
            #endif
            """
        case "common_composite.h":
            // WPE's common_composite.h `#include "common_blending.h"` so
            // ApplyComposite(COMPOSITE==1) can overlay via ApplyBlending(
            // BLENDMODE, …). Our include expander does NOT recurse into
            // builtin strings, so prepend the (guarded) blending header
            // verbatim to guarantee ApplyBlending is in scope. g_CompositeColor
            // / g_CompositeAlpha / g_CompositeOffset / COMPOSITEMONO are
            // identity for default values and aren't yet collected as
            // uniforms from headers — omitted until that wiring lands.
            let blending = builtinInclude(named: "common_blending.h") ?? ""
            return blending + "\n" + """
            #ifndef LIVEWALLPAPER_WPE_COMMON_COMPOSITE_H
            #define LIVEWALLPAPER_WPE_COMMON_COMPOSITE_H
            #define wpe_common_composite_included 1
            #ifndef COMPOSITE
            #define COMPOSITE 0
            #endif
            #ifndef BLENDMODE
            #define BLENDMODE 0
            #endif

            vec2 ApplyCompositeOffset(vec2 coord, vec2 resolution) {
                return coord;
            }

            vec4 ApplyComposite(vec4 baseColor, vec4 compositeColor) {
            #if COMPOSITE == 1
                // Overlay the effect onto the base with the shader's blend
                // mode (BLENDMODE==0 → ApplyBlending == mix == prior behavior).
                vec3 composited = ApplyBlending(BLENDMODE, baseColor.rgb, compositeColor.rgb, compositeColor.a);
                return vec4(composited, max(compositeColor.a, baseColor.a));
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
            // WPE workshop perspective effects (waterripple, waterwaves,
            // lightshafts, auto_sway, refract) build a 3×3 homography
            // by inverting the matrix that maps the unit square corners
            // to four screen-space points. Both `squareToQuad` and the
            // mat3 form of `inverse` ship in WPE's stock header; ours
            // were empty before, so every call surfaced as "no matching
            // overloaded function found".
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_PERSPECTIVE_H
            #define LIVEWALLPAPER_WPE_COMMON_PERSPECTIVE_H
            #define wpe_common_perspective_included 1

            mat3 squareToQuad(vec2 p0, vec2 p1, vec2 p2, vec2 p3) {
                vec2 d1 = p1 - p2;
                vec2 d2 = p3 - p2;
                vec2 s  = p0 - p1 + p2 - p3;
                float det = d1.x * d2.y - d2.x * d1.y;
                float g = (s.x * d2.y - d2.x * s.y) / det;
                float h = (d1.x * s.y - s.x * d1.y) / det;
                return mat3(
                    p1.x - p0.x + g * p1.x, p1.y - p0.y + g * p1.y, g,
                    p3.x - p0.x + h * p3.x, p3.y - p0.y + h * p3.y, h,
                    p0.x,                   p0.y,                   1.0
                );
            }

            // WPE shaders also feed `vec3` corner points (homogeneous
            // padding) into the same call. Delegate to the vec2 form so
            // both signatures resolve.
            mat3 squareToQuad(vec3 p0, vec3 p1, vec3 p2, vec3 p3) {
                return squareToQuad(p0.xy, p1.xy, p2.xy, p3.xy);
            }
            #endif
            """
        default:
            return nil
        }
    }

}
#endif
