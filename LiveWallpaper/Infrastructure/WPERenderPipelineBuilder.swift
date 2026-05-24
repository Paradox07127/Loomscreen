#if !LITE_BUILD
import Foundation

struct WPERenderPipelineBuilder: Sendable {
    private let shaderLoader: WPEShaderSourceLoader

    init(
        cacheRootURL: URL,
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.shaderLoader = WPEShaderSourceLoader(
            cacheRootURL: cacheRootURL,
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
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

    init(
        cacheRootURL: URL,
        engineAssetsRootURL: URL? = nil,
        tracer: WPEResolutionTracer? = nil
    ) {
        self.resolver = WPEMultiRootResourceResolver(
            primaryRootURL: cacheRootURL,
            dependencyMounts: [],
            engineAssetsRootURL: engineAssetsRootURL,
            tracer: tracer
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
            if normalized.hasPrefix("effect_") {
                return copyProgram(shaderName: shaderName, combos: combos)
            }
            guard WPEBuiltinShaderName.isGenericImageShader(shaderName) else {
                return nil
            }
            return genericImageProgram(shaderName: shaderName, combos: combos)
        }
    }

    /// WPE's `genericimage*` family with the SPRITESHEET combo on: the
    /// vertex shader must derive UVs from `g_Texture0Translation` +
    /// `g_Texture0Rotation` so the runtime can slice a single texture into
    /// N animation frames. Without the combo, fall back to the trivial
    /// copy program (the historical behaviour).
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
        uniform vec4 g_Texture0Rotation;
        varying vec2 v_TexCoord;

        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = g_Texture0Translation
                + a_TexCoord.x * g_Texture0Rotation.xy
                + a_TexCoord.y * g_Texture0Rotation.zw;
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
    // expressions; the WebGL2 (ANGLE) preprocessor instead raises
    // "unexpected token after conditional expression" for an unknown
    // identifier. Scan the expanded source for uppercase identifiers
    // referenced in preprocessor conditionals and emit `#define X 0` for
    // any that the prelude / combo values / shader body itself hasn't
    // already defined.
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

    // Identifiers inside `defined(X)` / `defined X` are existence
    // checks, not value reads. Remove them before scanning for
    // identifiers that need auto-defines.
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
        "CAST2", "CAST3", "CAST4", "CAST3X3"
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
            "#define atan2(y, x) atan((y), (x))",
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
            // Stock WPE `blur*a` separable-Gaussian helpers. WPE's
            // shipped `common_blur.h` ships these with a fixed
            // `g_Texture0` sampler bind because every blur pass in the
            // editor pipes the previous frame into slot 0; mirror the
            // same convention. Weights match the Sigg/Hadwiger 2005
            // formulation that WPE's `blur_precise_gaussian.frag`
            // expects.
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
            #endif
            """
        case "common_vertex.h":
            // Workshop authors `#include` this header but rarely depend
            // on its content; WPE's stock file exposes a handful of
            // vertex-shader convenience macros. A guarded empty stub is
            // enough to satisfy resolution without polluting the prelude.
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_VERTEX_H
            #define LIVEWALLPAPER_WPE_COMMON_VERTEX_H
            #define wpe_common_vertex_included 1
            #endif
            """
        case "common_fragment.h":
            return """
            #ifndef LIVEWALLPAPER_WPE_COMMON_FRAGMENT_H
            #define LIVEWALLPAPER_WPE_COMMON_FRAGMENT_H
            #define wpe_common_fragment_included 1
            #endif
            """
        case "common_blending.h":
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

    private func resolveExistingFileURL(relativePath: String) throws -> URL {
        do {
            return try resolver.resolveExistingFileURL(relativePath: relativePath)
        } catch SceneResourceResolver.ResolveError.fileMissing,
                SceneResourceResolver.ResolveError.pathEscape {
            throw WPERenderPipelineError.includeMissing(path: relativePath, requestedBy: "")
        }
    }
}
#endif
