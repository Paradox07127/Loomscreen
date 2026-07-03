#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Pure-Swift WPE-flavor GLSL → Metal Shading Language transpiler.
///
/// Scope: the canonical single-pass WPE effect shader. Inputs come from
/// `WPEShaderPreprocessor` (combos baked into `#define`s, includes
/// inlined, `texSample2D` mapped to `texture()`). The transpiler lifts
/// `uniform` / `varying` declarations into structured Metal inputs and
/// rewrites the body with type/intrinsic substitutions. Output signature
/// is fixed so the dispatcher binds without runtime reflection:
///
///   fragment float4 wpe_translated_fragment(
///       WPEStageIn in [[stage_in]],
///       constant WPEUniforms& u [[buffer(0)]],
///       texture2d<float> tex0 [[texture(0)]],
///       ...                                  // one per slot, tex0 … tex7
///       texture2d<float> tex7 [[texture(7)]] // see `customTextureSlotCount`
///   ) { ... }
///
/// Out of scope (returns `.translationFailed`):
///   - vertex shaders that aren't the standard fullscreen quad
///   - geometry/tessellation
///   - bit-level integer ops, atomics
///   - `discard` / `gl_FragData[*]` MRT
///   - sampler arrays, texture arrays, cube maps, 3D textures
///
/// Unsupported shaders surface as `metalRendererUnsupported` (the scene's
/// load error).
struct WPEShaderTranspiler {

    /// Each uniform occupies one or more float4 slots. Packing rule
    /// (Swift mirrors this when filling the buffer):
    ///
    ///   float            → (x, 0, 0, 0)
    ///   vec2             → (x, y, 0, 0)
    ///   vec3             → (x, y, z, 0)
    ///   vec4             → (x, y, z, w)
    ///   mat2/3/4         → consecutive vec4s starting at the slot
    ///   float[N] etc.    → N slots, one element per slot, scalar in `.x`
    ///
    /// Hard cap on a custom shader's flattened uniform slots. ≤256 slots (4 KB) ride the inline
    /// `setFragmentBytes` fast path; above that the binding falls back to a transient
    /// `setFragmentBuffer` (see `WPEMetalRenderExecutor.bindTranslatedUniformSlots`). Audio
    /// visualizers are what push past 256: `Simple_Audio_Bars` sits at 245, a stereo
    /// `audio_responsive_oscilloscope` needs 258. 1024 × 16 = 16 KB stays well inside the
    /// constant-buffer budget. The emitted `WPEUniforms.vals[]` is sized per shader, not to this cap.
    static let uniformSlotMaximum = 1024

    /// Number of texture slots the custom-shader path declares/binds.
    /// WPE shaders use g_Texture0–g_Texture7 (corpus max slot = 7, e.g.
    /// `effects/blend`). The generated MSL declares tex0…tex(N-1) and the
    /// dispatcher binds the same range; shaders using only low slots leave the
    /// rest bound to fallback textures (unchanged behavior). Single source of
    /// truth — the transpiler guards/signature and the dispatcher all use it.
    static let customTextureSlotCount = 8

    /// Translate a preprocessed WPE fragment shader to MSL.
    static func translateFragment(
        shaderName: String,
        preprocessedSource: String,
        comboValues: [String: Int] = [:],
        premultipliedInputSlots: Set<Int> = [],
        premultipliedOutput: Bool = false
    ) throws -> WPEShaderTranslationResult {
        let scrubbedSource = Self.scrubFragmentOutDeclarations(preprocessedSource)
        let activeSource = Self.stripInactivePreprocessorBranches(in: scrubbedSource)
        let lines = activeSource.components(separatedBy: "\n")

        var uniforms: [WPEUniformDecl] = []
        var samplers: [WPESamplerDecl] = []
        var varyings: [WPEVaryingDecl] = []
        var bodyLines: [String] = []

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                bodyLines.append(raw)
                continue
            }
            if trimmed.hasPrefix("#version") || trimmed.hasPrefix("#extension") {
                continue
            }
            if trimmed.hasPrefix("out vec4 wpe_fragColor")
                || trimmed.hasPrefix("out float4 wpe_fragColor")
                || trimmed.hasPrefix("out vec4 out_FragColor")
                || trimmed.hasPrefix("out float4 out_FragColor") {
                continue
            }
            if let sampler = WPESamplerDecl.parse(line: trimmed) {
                samplers.append(sampler)
                continue
            }
            if let uniform = WPEUniformDecl.parse(line: trimmed) {
                uniforms.append(uniform)
                continue
            }
            if let varying = WPEVaryingDecl.parse(line: trimmed) {
                varyings.append(varying)
                continue
            }
            bodyLines.append(raw)
        }

        let sortedSamplers = samplers.sorted { lhs, rhs in
            (Self.textureSlot(for: lhs.name) ?? .max) < (Self.textureSlot(for: rhs.name) ?? .max)
        }
        guard sortedSamplers.count <= Self.customTextureSlotCount else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' uses \(sortedSamplers.count) samplers; transpiler supports up to \(Self.customTextureSlotCount)"
            )
        }
        // WPE allows sampler slots g_Texture0–g_Texture7; the generated MSL
        // declares tex0…tex(customTextureSlotCount-1) and the dispatcher binds
        // the same range. A sampler at a higher slot would alias to an
        // undeclared `texN` (MSL compile failure), so reject it explicitly.
        if let maxSlot = sortedSamplers.compactMap({ Self.textureSlot(for: $0.name) }).max(),
           maxSlot >= Self.customTextureSlotCount {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' binds texture slot \(maxSlot); transpiler supports slots 0–\(Self.customTextureSlotCount - 1)"
            )
        }
        _ = !varyings.isEmpty || activeSource.contains("v_TexCoord") || activeSource.contains("gl_FragCoord")

        // Noise/detail textures (e.g. `util/noise`) are tiled: WPE samples them with
        // wrap/repeat at coords far outside [0,1]. Our single `linearSampler` is
        // clamp_to_edge, so without a repeat sampler those coords clamp to the texture
        // edge — collapsing filmgrain's tiled noise into a scrolling edge-smear cross-hatch.
        // Mark samplers the shader annotates as noise so their reads use `repeatSampler`;
        // the framebuffer / masks keep clamp (they're sampled in range, where it's a no-op).
        let repeatSamplers = Set(
            sortedSamplers
                .filter { ($0.comment?.lowercased().contains("noise")) == true }
                .map(\.name)
        )

        let body = bodyLines.joined(separator: "\n")
        guard let mainRange = Self.locateMain(in: body) else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' has no recognizable `void main()` entry point"
            )
        }
        let preMain = String(body[..<mainRange.lowerBound])
        let mainBody = String(body[mainRange])
        let postMain = String(body[mainRange.upperBound...])

        let varyingTypesByName = Dictionary(
            varyings.map { ($0.name, $0.metalType) },
            uniquingKeysWith: { _, last in last }
        )
        let preserveTexCoordZW = shouldPreserveTexCoordZW(shaderName: shaderName)
        let translatedHelpers = applySubstitutions(
            preMain + "\n" + postMain,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots,
            repeatSamplers: repeatSamplers
        )
        let translatedMain = translateMain(
            mainBody,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots,
            premultiplyOutput: premultipliedOutput,
            repeatSamplers: repeatSamplers
        )
        let helperMutableGlobals = extractProgramScopeMutableDeclarations(from: translatedHelpers)
        let helperResources = rewriteHelperResourceAccess(
            helpers: helperMutableGlobals.source,
            mainBody: translatedMain,
            uniforms: uniforms,
            samplers: sortedSamplers,
            mutableGlobals: helperMutableGlobals.declarations
        )

        let msl = renderMSL(
            shaderName: shaderName,
            uniforms: uniforms,
            samplers: sortedSamplers,
            varyings: varyings,
            helpers: helperResources.helpers,
            mainBody: helperResources.mainBody,
            mutableGlobals: helperMutableGlobals.declarations,
            comboValues: comboValues,
            premultipliedInputSlots: premultipliedInputSlots,
            premultipliedOutput: premultipliedOutput
        )

        var layout: [WPEUniformSlot] = []
        var nextSlot = 0
        for u in uniforms {
            let slotCount: Int
            if let len = u.arrayLength {
                slotCount = len
            } else {
                slotCount = Self.slotCount(for: u.type)
            }
            layout.append(WPEUniformSlot(
                name: u.name,
                glslType: u.type,
                slot: nextSlot,
                slotCount: slotCount,
                arrayLength: u.arrayLength,
                materialName: u.materialName,
                defaultValue: u.defaultValue
            ))
            nextSlot += slotCount
        }
        guard nextSlot <= Self.uniformSlotMaximum else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' needs \(nextSlot) uniform slots; transpiler caps at \(Self.uniformSlotMaximum)"
            )
        }

        return WPEShaderTranslationResult(
            mslSource: msl,
            samplers: sortedSamplers.map(\.name),
            uniformLayout: layout,
            totalSlots: nextSlot
        )
    }

    private static func slotCount(for glslType: String) -> Int {
        switch glslType {
        case "mat2": return 2
        case "mat3": return 3
        case "mat4": return 4
        default:    return 1
        }
    }

    // MARK: - Preprocessor conditionals

    private struct ConditionalFrame {
        let parentActive: Bool
        var active: Bool
        var branchTaken: Bool
    }

    /// Exposed for the vertex-uniform merge: a uniform declared only inside an
    /// INACTIVE `#if` branch of the fragment must not count as "already
    /// declared", or the merge skips it and the strip then removes it entirely
    /// (auto_sway declares g_Speed/g_Inertia only under `AA_VERSION == 1`).
    static func sourceWithInactiveBranchesStripped(_ source: String) -> String {
        stripInactivePreprocessorBranches(in: source)
    }

    private static func stripInactivePreprocessorBranches(in source: String) -> String {
        var macroValues: [String: Int] = [:]
        var definedMacros: Set<String> = []
        var frames: [ConditionalFrame] = []
        var output: [String] = []

        for line in source.components(separatedBy: "\n") {
            guard let directive = preprocessorDirective(in: line) else {
                if preprocessorIsActive(frames) {
                    output.append(line)
                }
                continue
            }

            switch directive.keyword {
            case "if":
                let parentActive = preprocessorIsActive(frames)
                let value = evaluatePreprocessorExpression(
                    directive.expression,
                    values: macroValues,
                    definedMacros: definedMacros
                )
                let active = parentActive && value != 0
                frames.append(ConditionalFrame(
                    parentActive: parentActive,
                    active: active,
                    branchTaken: active
                ))
            case "ifdef":
                let parentActive = preprocessorIsActive(frames)
                let name = directive.expression.trimmingCharacters(in: .whitespaces)
                let active = parentActive && definedMacros.contains(name)
                frames.append(ConditionalFrame(
                    parentActive: parentActive,
                    active: active,
                    branchTaken: active
                ))
            case "ifndef":
                let parentActive = preprocessorIsActive(frames)
                let name = directive.expression.trimmingCharacters(in: .whitespaces)
                let active = parentActive && !definedMacros.contains(name)
                frames.append(ConditionalFrame(
                    parentActive: parentActive,
                    active: active,
                    branchTaken: active
                ))
            case "elif":
                guard !frames.isEmpty else { continue }
                var frame = frames.removeLast()
                if frame.parentActive && !frame.branchTaken {
                    let value = evaluatePreprocessorExpression(
                        directive.expression,
                        values: macroValues,
                        definedMacros: definedMacros
                    )
                    frame.active = value != 0
                    frame.branchTaken = frame.active
                } else {
                    frame.active = false
                }
                frames.append(frame)
            case "else":
                guard !frames.isEmpty else { continue }
                var frame = frames.removeLast()
                frame.active = frame.parentActive && !frame.branchTaken
                frame.branchTaken = true
                frames.append(frame)
            case "endif":
                if !frames.isEmpty {
                    frames.removeLast()
                }
            case "define":
                guard preprocessorIsActive(frames) else { continue }
                if let definition = parsePreprocessorDefine(directive.expression, values: macroValues, definedMacros: definedMacros) {
                    definedMacros.insert(definition.name)
                    if let value = definition.value {
                        macroValues[definition.name] = value
                    } else {
                        macroValues.removeValue(forKey: definition.name)
                    }
                }
                output.append(line)
            case "undef":
                guard preprocessorIsActive(frames) else { continue }
                let name = directive.expression.trimmingCharacters(in: .whitespaces)
                definedMacros.remove(name)
                macroValues.removeValue(forKey: name)
            default:
                if preprocessorIsActive(frames) {
                    output.append(line)
                }
            }
        }

        return output.joined(separator: "\n")
    }

    private static func preprocessorIsActive(_ frames: [ConditionalFrame]) -> Bool {
        frames.allSatisfy(\.active)
    }

    private static func preprocessorDirective(in line: String) -> (keyword: String, expression: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let body = trimmed.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        let keyword = body.prefix(while: { $0.isLetter })
        guard !keyword.isEmpty else { return nil }
        let expressionStart = body.index(body.startIndex, offsetBy: keyword.count)
        let expression = body[expressionStart...].trimmingCharacters(in: .whitespaces)
        return (String(keyword), expression)
    }

    private static func parsePreprocessorDefine(
        _ expression: String,
        values: [String: Int],
        definedMacros: Set<String>
    ) -> (name: String, value: Int?)? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, isIdentifierStart(first) else { return nil }
        var nameEnd = trimmed.index(after: trimmed.startIndex)
        while nameEnd < trimmed.endIndex, isIdentifierCharacter(trimmed[nameEnd]) {
            nameEnd = trimmed.index(after: nameEnd)
        }
        let name = String(trimmed[..<nameEnd])
        if nameEnd < trimmed.endIndex, trimmed[nameEnd] == "(" {
            return (name, nil)
        }

        let rawValue = String(trimmed[nameEnd...])
            .components(separatedBy: "//")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !rawValue.isEmpty else {
            return (name, 1)
        }

        guard let value = parsePreprocessorExpression(rawValue, values: values, definedMacros: definedMacros) else {
            return (name, nil)
        }
        return (name, value)
    }

    private static func evaluatePreprocessorExpression(
        _ expression: String,
        values: [String: Int],
        definedMacros: Set<String>
    ) -> Int {
        let sanitized = sanitizeConditionalExpression(expression)
        return parsePreprocessorExpression(sanitized, values: values, definedMacros: definedMacros) ?? 0
    }

    /// WPE's preprocessor tolerates trailing junk in `#if` / `#elif` conditions — workshop shaders
    /// ship lines like `#elif AUDIOSAMPLES == 32;` (stray `;`) or `#if COND // note`. A `;`, `//`,
    /// or `/*` can never appear inside a valid conditional expression, so truncate at the first one;
    /// otherwise the strict tokenizer rejects the whole condition and the (often default) branch is
    /// silently dropped, leaving its declarations undefined in the emitted MSL.
    private static func sanitizeConditionalExpression(_ expression: String) -> String {
        var cutoff = expression.endIndex
        for marker in ["//", "/*", ";"] {
            if let range = expression.range(of: marker), range.lowerBound < cutoff {
                cutoff = range.lowerBound
            }
        }
        return String(expression[..<cutoff]).trimmingCharacters(in: .whitespaces)
    }

    private static func parsePreprocessorExpression(
        _ expression: String,
        values: [String: Int],
        definedMacros: Set<String>
    ) -> Int? {
        guard let tokens = PreprocessorExpressionParser.tokenize(expression) else {
            return nil
        }
        var parser = PreprocessorExpressionParser(tokens: tokens, values: values, definedMacros: definedMacros)
        return parser.parse()
    }

    private enum PreprocessorToken: Equatable {
        case number(Int)
        case identifier(String)
        case op(String)
        case lParen
        case rParen
        case end
    }

    private struct PreprocessorExpressionParser {
        let tokens: [PreprocessorToken]
        let values: [String: Int]
        let definedMacros: Set<String>
        var index = 0

        init(tokens: [PreprocessorToken], values: [String: Int], definedMacros: Set<String>) {
            self.tokens = tokens
            self.values = values
            self.definedMacros = definedMacros
        }

        mutating func parse() -> Int? {
            guard let value = parseOr(), peek == .end else {
                return nil
            }
            return value
        }

        private var peek: PreprocessorToken {
            tokens.indices.contains(index) ? tokens[index] : .end
        }

        private mutating func advance() -> PreprocessorToken {
            let token = peek
            index += 1
            return token
        }

        private mutating func matchOperator(_ op: String) -> Bool {
            if peek == .op(op) {
                _ = advance()
                return true
            }
            return false
        }

        private mutating func parseOr() -> Int? {
            guard var lhs = parseAnd() else { return nil }
            while matchOperator("||") {
                guard let rhs = parseAnd() else { return nil }
                lhs = lhs != 0 || rhs != 0 ? 1 : 0
            }
            return lhs
        }

        private mutating func parseAnd() -> Int? {
            guard var lhs = parseEquality() else { return nil }
            while matchOperator("&&") {
                guard let rhs = parseEquality() else { return nil }
                lhs = lhs != 0 && rhs != 0 ? 1 : 0
            }
            return lhs
        }

        private mutating func parseEquality() -> Int? {
            guard var lhs = parseRelational() else { return nil }
            while true {
                if matchOperator("==") {
                    guard let rhs = parseRelational() else { return nil }
                    lhs = lhs == rhs ? 1 : 0
                } else if matchOperator("!=") {
                    guard let rhs = parseRelational() else { return nil }
                    lhs = lhs != rhs ? 1 : 0
                } else {
                    return lhs
                }
            }
        }

        private mutating func parseRelational() -> Int? {
            guard var lhs = parseUnary() else { return nil }
            while true {
                if matchOperator(">=") {
                    guard let rhs = parseUnary() else { return nil }
                    lhs = lhs >= rhs ? 1 : 0
                } else if matchOperator("<=") {
                    guard let rhs = parseUnary() else { return nil }
                    lhs = lhs <= rhs ? 1 : 0
                } else if matchOperator(">") {
                    guard let rhs = parseUnary() else { return nil }
                    lhs = lhs > rhs ? 1 : 0
                } else if matchOperator("<") {
                    guard let rhs = parseUnary() else { return nil }
                    lhs = lhs < rhs ? 1 : 0
                } else {
                    return lhs
                }
            }
        }

        private mutating func parseUnary() -> Int? {
            if matchOperator("!") {
                guard let value = parseUnary() else { return nil }
                return value == 0 ? 1 : 0
            }
            if matchOperator("-") {
                guard let value = parseUnary() else { return nil }
                return -value
            }
            if matchOperator("+") {
                return parseUnary()
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Int? {
            switch advance() {
            case .number(let value):
                return value
            case .identifier("defined"):
                return parseDefinedOperator()
            case .identifier(let name):
                return values[name] ?? 0
            case .lParen:
                guard let value = parseOr(), peek == .rParen else { return nil }
                _ = advance()
                return value
            default:
                return nil
            }
        }

        private mutating func parseDefinedOperator() -> Int? {
            if peek == .lParen {
                _ = advance()
                guard case .identifier(let name) = advance(), peek == .rParen else {
                    return nil
                }
                _ = advance()
                return definedMacros.contains(name) ? 1 : 0
            }
            guard case .identifier(let name) = advance() else {
                return nil
            }
            return definedMacros.contains(name) ? 1 : 0
        }

        static func tokenize(_ expression: String) -> [PreprocessorToken]? {
            var tokens: [PreprocessorToken] = []
            var index = expression.startIndex

            while index < expression.endIndex {
                let ch = expression[index]
                if ch.isWhitespace {
                    index = expression.index(after: index)
                    continue
                }
                if ch == "/" {
                    let next = expression.index(after: index)
                    if next < expression.endIndex, expression[next] == "/" {
                        break
                    }
                    return nil
                }
                if ch.isNumber {
                    var end = expression.index(after: index)
                    if ch == "0", end < expression.endIndex, expression[end] == "x" || expression[end] == "X" {
                        end = expression.index(after: end)
                        let digitsStart = end
                        while end < expression.endIndex, expression[end].isHexDigit {
                            end = expression.index(after: end)
                        }
                        guard digitsStart < end,
                              let value = Int(expression[digitsStart..<end], radix: 16) else {
                            return nil
                        }
                        tokens.append(.number(value))
                        index = end
                        continue
                    }
                    while end < expression.endIndex, expression[end].isNumber {
                        end = expression.index(after: end)
                    }
                    guard let value = Int(expression[index..<end]) else {
                        return nil
                    }
                    tokens.append(.number(value))
                    index = end
                    continue
                }
                if isIdentifierStart(ch) {
                    var end = expression.index(after: index)
                    while end < expression.endIndex, isIdentifierCharacter(expression[end]) {
                        end = expression.index(after: end)
                    }
                    tokens.append(.identifier(String(expression[index..<end])))
                    index = end
                    continue
                }
                let next = expression.index(after: index)
                if next < expression.endIndex {
                    let two = String(expression[index...next])
                    if ["&&", "||", "==", "!=", ">=", "<="].contains(two) {
                        tokens.append(.op(two))
                        index = expression.index(after: next)
                        continue
                    }
                }
                switch ch {
                case "(":
                    tokens.append(.lParen)
                case ")":
                    tokens.append(.rParen)
                case "!", ">", "<", "+", "-":
                    tokens.append(.op(String(ch)))
                default:
                    return nil
                }
                index = expression.index(after: index)
            }

            tokens.append(.end)
            return tokens
        }
    }

    // MARK: - main() handling

    /// Range covering everything from `void main()` through the matching closing brace.
    private static func locateMain(in source: String) -> Range<String.Index>? {
        guard let keywordRange = source.range(of: "void main") else { return nil }
        guard let openBrace = source.range(of: "{", range: keywordRange.upperBound..<source.endIndex) else {
            return nil
        }
        var depth = 1
        var index = openBrace.upperBound
        while index < source.endIndex && depth > 0 {
            let ch = source[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1 }
            index = source.index(after: index)
        }
        guard depth == 0 else { return nil }
        return keywordRange.lowerBound..<index
    }

    /// Strip the `void main() { ... }` wrapper and rebuild it as Metal-friendly statements.
    private static func translateMain(
        _ source: String,
        varyingTypesByName: [String: String] = [:],
        preserveTexCoordZW: Bool = false,
        premultipliedInputSlots: Set<Int> = [],
        premultiplyOutput: Bool = false,
        repeatSamplers: Set<String> = []
    ) -> String {
        guard let openBrace = source.range(of: "{") else { return "" }
        guard let closeBrace = source.range(of: "}", options: .backwards) else { return "" }
        var inner = String(source[openBrace.upperBound..<closeBrace.lowerBound])
        inner = applySubstitutions(
            inner,
            rewriteProgramScopeConsts: false,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots,
            repeatSamplers: repeatSamplers
        )
        inner = markLocalVariableDeclarationsMaybeUnused(inner)

        let usesGLOut = inner.contains("gl_FragColor")
        let usesWPEOut = inner.contains("wpe_fragColor")
        let usesOutFragColor = inner.contains("out_FragColor")
        if usesGLOut || usesWPEOut || usesOutFragColor {
            if usesGLOut {
                inner = inner.replacingOccurrences(of: "gl_FragColor", with: "out_color")
            }
            if usesWPEOut {
                inner = inner.replacingOccurrences(of: "wpe_fragColor", with: "out_color")
            }
            if usesOutFragColor {
                inner = inner.replacingOccurrences(of: "out_FragColor", with: "out_color")
            }
            inner = "float4 out_color = float4(0.0);\n"
                + inner
                + "\nreturn \(premultiplyOutput ? "wpe_premultiply_output(out_color)" : "out_color");\n"
        } else {
            let zero = premultiplyOutput ? "wpe_premultiply_output(float4(0.0))" : "float4(0.0)"
            inner = inner + "\nreturn \(zero);\n"
        }
        return inner
    }

    // MARK: - Type / intrinsic substitutions

    private static func markLocalVariableDeclarationsMaybeUnused(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("[[maybe_unused]]"),
                  !trimmed.hasPrefix("for "),
                  !trimmed.hasPrefix("for("),
                  line.range(
                    of: #"^\s*(?:const\s+)?(?:auto|float(?:[234](?:x[234])?)?|int[234]?|uint[234]?|bool[234]?)\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*\[[^\]]+\])?\s*(?:=|;)"#,
                    options: .regularExpression
                  ) != nil else {
                return line
            }

            let indentEnd = line.firstIndex { !$0.isWhitespace } ?? line.startIndex
            return String(line[..<indentEnd]) + "[[maybe_unused]] " + String(line[indentEnd...])
        }.joined(separator: "\n")
    }

    /// Apply token-level substitutions for the GLSL→MSL gap.
    private static func applySubstitutions(
        _ source: String,
        rewriteProgramScopeConsts: Bool = true,
        varyingTypesByName: [String: String] = [:],
        preserveTexCoordZW: Bool = false,
        premultipliedInputSlots: Set<Int> = [],
        repeatSamplers: Set<String> = []
    ) -> String {
        var s = source

        for (glsl, msl) in [
            ("ivec4", "int4"), ("ivec3", "int3"), ("ivec2", "int2"),
            ("uvec4", "uint4"), ("uvec3", "uint3"), ("uvec2", "uint2"),
            ("bvec4", "bool4"), ("bvec3", "bool3"), ("bvec2", "bool2"),
            ("vec4", "float4"), ("vec3", "float3"), ("vec2", "float2"),
            ("mat4", "float4x4"), ("mat3", "float3x3"), ("mat2", "float2x2")
        ] {
            s = wordReplace(s, find: glsl, replace: msl)
        }

        s = wordReplace(s, find: "frac", replace: "fract")
        s = wordReplace(s, find: "atan2", replace: "atan2")
        s = wordReplace(s, find: "lerp", replace: "mix")
        // GLSL derivative builtins → MSL spelling (no sign change: WPE's ddx/ddy
        // map straight to dfdx/dfdy; the GL-only ddy(-x) negation is not wanted).
        s = wordReplace(s, find: "dFdx", replace: "dfdx")
        s = wordReplace(s, find: "dFdy", replace: "dfdy")
        s = rewriteSmoothstepCalls(s)

        if rewriteProgramScopeConsts {
            s = rewriteProgramScopeConstDeclarations(s)
        }
        s = rewriteReservedIdentifiers(s)
        s = canonicalizeTextureSampleAliases(s)
        s = rewriteTextureLodCalls(s, premultipliedInputSlots: premultipliedInputSlots, repeatSamplers: repeatSamplers)
        s = rewriteTextureCalls(s, premultipliedInputSlots: premultipliedInputSlots, repeatSamplers: repeatSamplers)
        s = rewriteTexCoordTextureSampleUVFallback(s)
        s = rewriteTextureSampleNarrowing(s)
        s = rewriteVector4TextureSampleLocalsInSampleCoordinates(s)
        s = rewriteSwizzledMixAssignments(s)
        s = rewriteUnsignedFloatModuloAssignments(s)
        s = rewriteFloatAssignmentsFromVectorExpressions(s)
        s = rewritePointerPositionFloatAssignments(s)
        s = rewriteTextureResolutionVector2Assignments(s)
        s = rewriteVectorConstructorNarrowing(s)
        s = rewriteTexCoordVector2Arithmetic(s, varyingTypesByName: varyingTypesByName)
        s = rewriteTexCoordMaskUVFallback(
            s,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW
        )
        s = rewriteGLSLArrayConstructors(s)
        s = rewriteArrayCopyInitialization(s)
        s = rewriteFloatArraySubscripts(s)

        s = rewriteReferenceParameters(s)

        s = stripInParameterQualifier(s)

        return s
    }

    /// GLSL leaves `smoothstep(edge0, edge1, x)` undefined when the two edges
    /// are equal. Several WPE audio shaders intentionally collapse smoothing to
    /// zero at rest; Metal can turn the resulting division by zero into NaNs
    /// that then pollute premultiplied alpha. Route calls through a finite helper
    /// that behaves like a hard threshold for degenerate edges.
    private static func rewriteSmoothstepCalls(_ source: String) -> String {
        let pattern = #"(?<![:A-Za-z0-9_])smoothstep\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "wpe_smoothstep("
        )
    }

    private static func canonicalizeTextureSampleAliases(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#define texSample2D")
                || trimmed.hasPrefix("#define texSample2DLod")
                || trimmed.hasPrefix("#define texture2D") {
                return "// disabled texture sample alias macro: \(line)"
            }

            var rewritten = wordReplace(line, find: "texSample2DLod", replace: "textureLod")
            rewritten = wordReplace(rewritten, find: "texSample2D", replace: "texture")
            rewritten = wordReplace(rewritten, find: "texture2D", replace: "texture")
            return rewritten
        }.joined(separator: "\n")
    }

    /// Metal requires program-scope variables to live in the constant address
    /// space, while computed initializers must avoid global constructors.
    private static func rewriteProgramScopeConstDeclarations(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var depth = 0
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            var line = String(source[lineStart..<lineEnd])
            if depth == 0 {
                line = rewriteProgramScopeConstLine(line)
            }
            result += line
            if lineEnd < source.endIndex {
                result.append("\n")
            }

            for ch in line {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth = max(0, depth - 1)
                }
            }

            guard lineEnd < source.endIndex else { break }
            lineStart = source.index(after: lineEnd)
        }

        return result
    }

    private static func rewriteProgramScopeConstLine(_ line: String) -> String {
        let typePattern = #"(?:float|half|int|uint|bool)(?:[234](?:x[234])?)?"#
        let declarationPattern = #"^(\s*)const\s+(\#(typePattern))\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+);\s*$"#
        if let regex = try? NSRegularExpression(pattern: declarationPattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let indentRange = Range(match.range(at: 1), in: line),
           let nameRange = Range(match.range(at: 3), in: line),
           let rhsRange = Range(match.range(at: 4), in: line) {
            let rhs = String(line[rhsRange])
            if programScopeInitializerNeedsExpansion(rhs) {
                return "\(line[indentRange])#define \(line[nameRange]) (\(rhs))"
            }
        }

        let pattern = #"^(\s*)const\s+(\#(typePattern))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return line
        }
        return regex.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..., in: line),
            withTemplate: "$1constant $2"
        )
    }

    private static func programScopeInitializerNeedsExpansion(_ rhs: String) -> Bool {
        if rhs.range(of: #"\b[ug]_[A-Za-z0-9_]*\b"#, options: .regularExpression) != nil {
            return true
        }
        let functionNames = [
            "abs", "acos", "asin", "atan", "ceil", "clamp", "cos", "cross", "distance",
            "dot", "exp", "floor", "fract", "length", "log", "max", "min", "mix",
            "normalize", "pow", "reflect", "refract", "round", "sign", "sin", "smoothstep",
            "sqrt", "step", "tan"
        ]
        let joined = functionNames.joined(separator: "|")
        let pattern = #"(?<![A-Za-z0-9_])(\#(joined))\s*\("#
        return rhs.range(of: pattern, options: .regularExpression) != nil
    }

    private struct ProgramScopeMutableDecl: Hashable {
        let metalType: String
        let name: String
        let initializer: String

        var helperParameterType: String {
            "thread \(metalType)&"
        }
    }

    /// GLSL permits writable globals as per-fragment scratch state; MSL rejects
    /// non-`constant` program-scope variables. Move simple scratch declarations
    /// into `wpe_translated_fragment` and thread them through helper references.
    private static func extractProgramScopeMutableDeclarations(
        from source: String
    ) -> (source: String, declarations: [ProgramScopeMutableDecl]) {
        var declarations: [ProgramScopeMutableDecl] = []
        var output: [String] = []
        var depth = 0

        for line in source.components(separatedBy: "\n") {
            if depth == 0, let declaration = parseProgramScopeMutableDeclarationLine(line) {
                declarations.append(declaration)
            } else {
                output.append(line)
            }

            for ch in line {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth = max(0, depth - 1)
                }
            }
        }

        return (output.joined(separator: "\n"), declarations)
    }

    private static func parseProgramScopeMutableDeclarationLine(_ line: String) -> ProgramScopeMutableDecl? {
        let typePattern = #"(?:float|half|int|uint|bool)(?:[234](?:x[234])?)?"#
        let pattern = #"^\s*(?!const\b)(?!constant\b)(\#(typePattern))\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*(.*?))?\s*;\s*(?://.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let typeRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let metalType = String(line[typeRange])
        let initializer: String
        if match.range(at: 3).location != NSNotFound,
           let initializerRange = Range(match.range(at: 3), in: line) {
            initializer = String(line[initializerRange]).trimmingCharacters(in: .whitespaces)
        } else {
            initializer = zeroInitializer(forMetalType: metalType)
        }

        return ProgramScopeMutableDecl(
            metalType: metalType,
            name: String(line[nameRange]),
            initializer: initializer.isEmpty ? zeroInitializer(forMetalType: metalType) : initializer
        )
    }

    private static func zeroInitializer(forMetalType metalType: String) -> String {
        if metalType == "bool" { return "false" }
        if metalType.hasPrefix("bool") { return "\(metalType)(false)" }
        if metalType == "int" || metalType == "uint" { return "0" }
        if metalType.hasPrefix("int") || metalType.hasPrefix("uint") { return "\(metalType)(0)" }
        if metalType == "float" || metalType == "half" { return "0.0" }
        return "\(metalType)(0.0)"
    }

    /// Rewrite WPE shaders that use GLSL-style float modulo for an unsigned bucket index.
    private static func rewriteUnsignedFloatModuloAssignments(_ source: String) -> String {
        let pattern = #"\buint\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]+?)\s*%\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "uint $1 = uint(fmod(float($2), float($3)));"
        )
    }

    /// Some WPE workshop shaders use HLSL-style inference in local declarations,
    /// e.g. `float pointer = g_PointerPosition.xy * speed;`. Infer the MSL type
    /// for obvious vector expressions, but leave texture samples alone because
    /// `texture(...).r` style scalar extraction is a separate compatibility rule.
    private static func rewriteFloatAssignmentsFromVectorExpressions(_ source: String) -> String {
        let pattern = #"\bfloat\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]*(?:\.[xyzwrgba]{2,4}|float[234]\s*\()[^;\n]*);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let rhsRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let rhs = String(result[rhsRange])
            guard !rhs.contains(".sample("), !rhs.contains("texture") else {
                continue
            }
            let name = result[nameRange]
            result.replaceSubrange(fullRange, with: "auto \(name) = \(rhs);")
        }
        return result
    }

    /// WPE's cursor uniform is a vec2, but several workshop shaders declare
    /// derived pointer offsets as `float` and rely on HLSL-style inference.
    private static func rewritePointerPositionFloatAssignments(_ source: String) -> String {
        let pattern = #"\bfloat\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]*\bg_PointerPosition\b[^;\n]*);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let rhsRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let rhs = String(result[rhsRange])
            guard !rhs.contains(".sample("), !rhs.contains("texture") else {
                continue
            }
            let name = result[nameRange]
            result.replaceSubrange(fullRange, with: "auto \(name) = \(rhs);")
        }
        return result
    }

    /// WPE shaders sometimes use `g_TextureNResolution` as a vec2 scale in
    /// compound assignments, even though the uniform is declared as vec4.
    private static func rewriteTextureResolutionVector2Assignments(_ source: String) -> String {
        let declarationPattern = #"\bfloat2\s+([A-Za-z_][A-Za-z0-9_]*)\b"#
        guard let declarationRegex = try? NSRegularExpression(pattern: declarationPattern) else {
            return source
        }
        let declarationMatches = declarationRegex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        let vector2Names = declarationMatches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[range])
        }
        guard !vector2Names.isEmpty else {
            return source
        }

        var result = source
        for name in vector2Names {
            let escapedName = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(\b"# + escapedName + #"\s*[+\-*/]?=\s*[^;\n]*?)\b(g_Texture[0-9]+Resolution)\b(?!\s*\.)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let prefixRange = Range(match.range(at: 1), in: result),
                      let resolutionRange = Range(match.range(at: 2), in: result) else {
                    continue
                }
                result.replaceSubrange(
                    fullRange,
                    with: "\(result[prefixRange])\(result[resolutionRange]).xy"
                )
            }
        }
        return result
    }

    /// Metal texture2d sampling requires float2 UVs. WPE often carries extra
    /// UV data in zw and passes the full v_TexCoord vector to texture().
    private static func rewriteTexCoordTextureSampleUVFallback(_ source: String) -> String {
        // Also narrow the 3-arg LOD form `.sample(linearSampler, v_TexCoord, level(lod))`,
        // not just the 2-arg form, so vec3/vec4 v_TexCoord shaders that sample with an
        // explicit LOD still resolve to a float2 coordinate.
        let pattern = #"(\.sample\s*\(\s*linearSampler\s*,\s*)v_TexCoord(\s*(?:,\s*level\s*\([^;\n]+\))?\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "$1v_TexCoord.xy$2"
        )
    }

    /// Texture-sample locals are float4, but WPE effects also use them as 2D
    /// offset vectors inside later texture coordinates.
    private static func rewriteVector4TextureSampleLocalsInSampleCoordinates(_ source: String) -> String {
        let declarationPattern = #"\bfloat4\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[A-Za-z_][A-Za-z0-9_]*\.sample|wpe_unpremultiply_sample)\s*\("#
        guard let declarationRegex = try? NSRegularExpression(pattern: declarationPattern) else {
            return source
        }
        let names = declarationRegex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[range])
        }
        guard !names.isEmpty else {
            return source
        }

        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let needle = ".sample("

        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                var cursor = source.index(index, offsetBy: needle.count)
                var depth = 1
                var commaIndex: String.Index?
                while cursor < source.endIndex && depth > 0 {
                    let ch = source[cursor]
                    if ch == "(" { depth += 1 }
                    else if ch == ")" { depth -= 1 }
                    else if ch == "," && depth == 1 && commaIndex == nil {
                        commaIndex = cursor
                    }
                    if depth > 0 {
                        cursor = source.index(after: cursor)
                    }
                }
                if let comma = commaIndex, cursor < source.endIndex {
                    let coordinateStart = source.index(after: comma)
                    var coordinate = String(source[coordinateStart..<cursor])
                    for name in names {
                        coordinate = wordReplaceUnlessMemberAccess(coordinate, find: name, replace: "\(name).xy")
                    }
                    result += source[index..<coordinateStart]
                    result += coordinate
                    result += ")"
                    index = source.index(after: cursor)
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Metal will not implicitly narrow a float4 constructor into float3.
    private static func rewriteVectorConstructorNarrowing(_ source: String) -> String {
        let pattern = #"\bfloat3\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(float4\s*\([^;\n]+\))\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "float3 $1 = $2.rgb;"
        )
    }

    /// Rename GLSL identifiers that are legal in WPE shaders but reserved by Metal.
    private static func rewriteReservedIdentifiers(_ source: String) -> String {
        var result = wordReplace(source, find: "kernel", replace: "kernelValues")
        result = wordReplace(result, find: "or", replace: "orValue")
        result = wordReplace(result, find: "fragment", replace: "fragmentValue")
        return result
    }

    /// GLSL permits assigning a texture sample to narrower vector/scalar locals.
    /// Metal samples return float4, so make the intended channel extraction explicit.
    private static func rewriteTextureSampleNarrowing(_ source: String) -> String {
        let samplePattern = #"(?:[A-Za-z_][A-Za-z0-9_]*\.sample|wpe_unpremultiply_sample)\([^;\n]+\)"#
        let pattern = #"\b(float|float2|float3)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("# + samplePattern + #")\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let typeRange = Range(match.range(at: 1), in: result),
                  let nameRange = Range(match.range(at: 2), in: result),
                  let rhsRange = Range(match.range(at: 3), in: result) else {
                continue
            }
            let type = String(result[typeRange])
            let name = result[nameRange]
            let rhs = result[rhsRange]
            let swizzle: String
            switch type {
            case "float":
                swizzle = ".r"
            case "float2":
                swizzle = ".rg"
            case "float3":
                swizzle = ".rgb"
            default:
                continue
            }
            result.replaceSubrange(fullRange, with: "\(type) \(name) = \(rhs)\(swizzle);")
        }
        return result
    }

    /// GLSL permits `color.rgb = mix(color, replacementRgb, mask)`, relying on
    /// assignment narrowing. Metal requires the mixed vector widths to match.
    private static func rewriteSwizzledMixAssignments(_ source: String) -> String {
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_]*)\.(rgb|xyz|rg|xy)\s*=\s*mix\s*\(\s*\1\s*,"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "$1.$2 = mix($1.$2,"
        )
    }

    /// WPE workshop shaders often declare v_TexCoord as vec3/vec4 while using
    /// it as a vec2 UV in arithmetic.
    private static func rewriteTexCoordVector2Arithmetic(
        _ source: String,
        varyingTypesByName: [String: String]
    ) -> String {
        let pattern = #"\bv_TexCoord\s*([+\-])\s*((?:float2|CAST2)\s*\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        var result = regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "v_TexCoord.xy $1 $2"
        )

        guard let texCoordType = varyingTypesByName["v_TexCoord"],
              ["float3", "float4"].contains(texCoordType) else {
            return result
        }

        let declarationPattern = #"\bfloat2\s+([A-Za-z_][A-Za-z0-9_]*)\b"#
        guard let declarationRegex = try? NSRegularExpression(pattern: declarationPattern) else {
            return result
        }
        let vector2Names = Set(
            declarationRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
                .compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: result) else {
                        return nil
                    }
                    return String(result[range])
                }
        )
        guard !vector2Names.isEmpty else {
            return result
        }

        result = result.components(separatedBy: "\n").map { line in
            rewriteTexCoordVector2AssignmentLine(line, vector2Names: vector2Names)
        }.joined(separator: "\n")
        return result
    }

    private static func rewriteTexCoordVector2AssignmentLine(
        _ line: String,
        vector2Names: Set<String>
    ) -> String {
        guard line.contains("v_TexCoord"),
              let semicolon = line.firstIndex(of: ";"),
              let equal = line.firstIndex(of: "=") else {
            return line
        }
        let lhs = String(line[..<equal])
        let isVector2Declaration = lhs.range(
            of: #"\bfloat2\s+[A-Za-z_][A-Za-z0-9_]*\s*$"#,
            options: .regularExpression
        ) != nil
        let isKnownVector2Assignment = vector2Names.contains(lhs.trimmingCharacters(in: .whitespaces))
        guard isVector2Declaration || isKnownVector2Assignment else {
            return line
        }

        let rhsStart = line.index(after: equal)
        let rhs = String(line[rhsStart..<semicolon])
        let rewritten = wordReplaceUnlessMemberAccess(rhs, find: "v_TexCoord", replace: "v_TexCoord.xy")
        guard rewritten != rhs else {
            return line
        }
        return String(line[..<rhsStart]) + rewritten + String(line[semicolon...])
    }

    /// waterwaves/waterflow compute a resolution-scaled mask UV into `v_TexCoord.zw`
    /// (`uv·res.zw/res.xy`), which the fragment-only path synthesizes byte-for-byte via
    /// `wpe_texcoord_with_resolution(in.uv, g_Texture1Resolution)`. For those we keep the
    /// `.zw` sample so the mask padding correction survives. For every other shader the
    /// synthesized `.zw` is NOT guaranteed to match the source `.vert` (e.g. blur step,
    /// clipping-mask transforms), so we keep the historical `.xy` fallback.
    private static func rewriteTexCoordMaskUVFallback(
        _ source: String,
        varyingTypesByName: [String: String],
        preserveTexCoordZW: Bool
    ) -> String {
        guard preserveTexCoordZW, varyingTypesByName["v_TexCoord"] == "float4" else {
            return source.replacingOccurrences(of: "v_TexCoord.zw", with: "v_TexCoord.xy")
        }
        return source
    }

    /// These effects synthesize a `v_TexCoord.zw` that matches `wpe_texcoord_with_resolution`
    /// (resolution-scaled mask/flow UV) in their source `.vert`, so the reconstructed `.zw`
    /// is correct and must be preserved. `shake` samples its flow map (the per-pixel
    /// displacement direction) at `.zw`; downgrading it to `.xy` read the flow field from
    /// the wrong coordinates and turned the glitch/motion into a diagonal smear. Other
    /// float4-`v_TexCoord` effects whose `.zw` we can't yet vouch for keep historical `.xy`.
    private static func shouldPreserveTexCoordZW(shaderName: String) -> Bool {
        let normalized = shaderName
            .lowercased()
            .replacingOccurrences(of: ".frag", with: "")
            .replacingOccurrences(of: ".vert", with: "")
        for family in ["waterwaves", "waterflow", "shake"] {
            if normalized == "effect_\(family)"
                || normalized == "effects/\(family)"
                || normalized.hasSuffix("/effects/\(family)") {
                return true
            }
        }
        return false
    }

    /// Metal accepts aggregate array initializers, not GLSL constructor syntax
    /// such as `float2[n](...)`.
    private static func rewriteGLSLArrayConstructors(_ source: String) -> String {
        let typePattern = #"(?:(?:float[234]x[234])|(?:(?:float|int|uint|bool)(?:[234])?))"#
        let pattern = #"\b(const\s+)?("# + typePattern + #")\s+([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*\]\s*=\s*("# + typePattern + #")\s*\[\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*\]\s*\(([^;\n]+)\)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        var renamedArrays: [(from: String, to: String)] = []
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let declarationTypeRange = Range(match.range(at: 2), in: result),
                  let nameRange = Range(match.range(at: 3), in: result),
                  let declarationCountRange = Range(match.range(at: 4), in: result),
                  let constructorTypeRange = Range(match.range(at: 5), in: result),
                  let constructorCountRange = Range(match.range(at: 6), in: result),
                  let valuesRange = Range(match.range(at: 7), in: result) else {
                continue
            }
            let declarationType = String(result[declarationTypeRange])
            let constructorType = String(result[constructorTypeRange])
            let declarationCount = String(result[declarationCountRange])
            let constructorCount = String(result[constructorCountRange])
            guard declarationType == constructorType, declarationCount == constructorCount else {
                continue
            }
            let qualifier: String
            if match.range(at: 1).location != NSNotFound,
               let qualifierRange = Range(match.range(at: 1), in: result) {
                qualifier = String(result[qualifierRange])
            } else {
                qualifier = ""
            }
            let outputQualifier = qualifier == "const " && isTopLevel(fullRange.lowerBound, in: result) ? "constant " : qualifier
            let name = String(result[nameRange])
            let outputName = name == "kernel" ? "kernelValues" : name
            if outputName != name {
                renamedArrays.append((from: name, to: outputName))
            }
            let values = result[valuesRange]
            result.replaceSubrange(
                fullRange,
                with: "\(outputQualifier)\(declarationType) \(outputName)[\(declarationCount)] = { \(values) };"
            )
        }
        for renamedArray in renamedArrays {
            result = wordReplace(result, find: renamedArray.from, replace: renamedArray.to)
        }
        return result
    }

    private static func isTopLevel(_ index: String.Index, in source: String) -> Bool {
        var depth = 0
        var cursor = source.startIndex
        while cursor < index {
            if source[cursor] == "{" {
                depth += 1
            } else if source[cursor] == "}" {
                depth = max(0, depth - 1)
            }
            cursor = source.index(after: cursor)
        }
        return depth == 0
    }

    /// GLSL allows initializing a local array by copying another array
    /// (`float left[N] = g_AudioSpectrum32Left;`), but MSL requires an initializer list.
    /// Bind a reference instead (`thread float (&left)[N] = g_AudioSpectrum32Left;`) — the local
    /// is read-only here, so an alias is equivalent and avoids the (illegal) copy.
    private static func rewriteArrayCopyInitialization(_ source: String) -> String {
        let typePattern = #"(?:float|int|uint|bool)(?:[234])?"#
        let pattern = #"(?m)^([ \t]*)("# + typePattern + #")\s+([A-Za-z_]\w*)\s*\[\s*([A-Za-z_0-9]+)\s*\]\s*=\s*([A-Za-z_]\w*)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "$1thread $2 (&$3)[$4] = $5;"
        )
    }

    /// MSL array subscripts must be integers, but WPE shaders routinely index with a `float`
    /// loop/bin variable (`float i = floor(...); left[i]`). Wrap subscripts that use a
    /// float-declared scalar in `int(...)`. Only bare-identifier subscripts of known float locals
    /// are touched, so integer indices and expression subscripts are left unchanged.
    private static func rewriteFloatArraySubscripts(_ source: String) -> String {
        let floatDeclPattern = #"\bfloat\s+([A-Za-z_]\w*)\s*="#
        let nonFloatDeclPattern = #"\b(?:int|uint|bool|float[234]|int[234]|uint[234]|bool[234])\s+([A-Za-z_]\w*)\b"#
        guard let floatDeclRegex = try? NSRegularExpression(pattern: floatDeclPattern),
              let nonFloatDeclRegex = try? NSRegularExpression(pattern: nonFloatDeclPattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        var floatVars: Set<String> = []
        for match in floatDeclRegex.matches(in: source, range: range) {
            if let nameRange = Range(match.range(at: 1), in: source) {
                floatVars.insert(String(source[nameRange]))
            }
        }
        // Scope guard: this pass is name-based, not scope-aware. If a name is ALSO declared as an
        // int/vector/bool elsewhere in the shader (e.g. one function's `float i` vs another's
        // `for (int i)`), leave its subscripts alone rather than rewriting an unrelated int index.
        var nonFloatVars: Set<String> = []
        for match in nonFloatDeclRegex.matches(in: source, range: range) {
            if let nameRange = Range(match.range(at: 1), in: source) {
                nonFloatVars.insert(String(source[nameRange]))
            }
        }
        floatVars.subtract(nonFloatVars)
        guard !floatVars.isEmpty else { return source }

        var result = source
        for name in floatVars {
            let subscriptPattern = #"\[\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\]"#
            guard let regex = try? NSRegularExpression(pattern: subscriptPattern) else { continue }
            let fullRange = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: fullRange,
                withTemplate: "[int(\(name))]"
            )
        }
        return result
    }

    /// Rewrite GLSL `inout T name` / `out T name` parameter qualifiers to Metal's `thread T& name`.
    private static func rewriteReferenceParameters(_ source: String) -> String {
        let pattern = #"\b(inout|out)\s+([A-Za-z_][A-Za-z0-9_]*(?:\d+x\d+)?)\s+([A-Za-z_][A-Za-z0-9_]*)(?=\s*[,)])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "thread $2& $3"
        )
    }

    /// Strip GLSL's `in T name` parameter qualifier (MSL has no equivalent — `in` is the implicit default).
    private static func stripInParameterQualifier(_ source: String) -> String {
        let pattern = #"\bin\s+([A-Za-z_][A-Za-z0-9_]*(?:\d+x\d+)?)\s+([A-Za-z_][A-Za-z0-9_]*)(?=\s*[,)])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "$1 $2"
        )
    }

    /// Scrub WPE fragment `out` declarations (`out vec4 out_FragColor;` and `out vec4 wpe_fragColor;`, plus their already-substituted `float4` twins) from anywhere in the source.
    static func scrubFragmentOutDeclarations(_ source: String) -> String {
        let pattern = #"out\s+(vec4|float4)\s+(wpe_fragColor|out_FragColor)\s*;\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: ""
        )
    }

    /// Substring replacement that respects identifier boundaries.
    private static func wordReplace(_ source: String, find: String, replace: String) -> String {
        guard !find.isEmpty else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix(find) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                let afterIndex = source.index(index, offsetBy: find.count)
                let nextOK: Bool
                if afterIndex >= source.endIndex {
                    nextOK = true
                } else {
                    let n = source[afterIndex]
                    nextOK = !n.isLetter && !n.isNumber && n != "_"
                }
                if priorOK && nextOK {
                    result += replace
                    index = afterIndex
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Identifier replacement variant for expressions where an existing
    /// swizzle/member access must be left alone.
    private static func wordReplaceUnlessMemberAccess(_ source: String, find: String, replace: String) -> String {
        guard !find.isEmpty else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix(find) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                let afterIndex = source.index(index, offsetBy: find.count)
                let nextOK: Bool
                if afterIndex >= source.endIndex {
                    nextOK = true
                } else {
                    let n = source[afterIndex]
                    nextOK = !n.isLetter && !n.isNumber && n != "_" && n != "."
                }
                if priorOK && nextOK {
                    result += replace
                    index = afterIndex
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Rewrite `textureLod(<sampler>, <uv>, <lod>)` (from WPE's `texSample2DLod`)
    /// into Metal `<sampler>.sample(linearSampler, <uv>, level(<lod>))`. `level()`
    /// is the MSL explicit-LOD specifier; without this the literal `textureLod`
    /// survives and `makeLibrary` fails. Runs before `rewriteTextureCalls` so the
    /// `texture(` pass never sees `textureLod`.
    private static func rewriteTextureLodCalls(
        _ source: String,
        premultipliedInputSlots: Set<Int> = [],
        repeatSamplers: Set<String> = []
    ) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let needle = "textureLod("
        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                if priorOK {
                    var cursor = source.index(index, offsetBy: needle.count)
                    var depth = 1
                    var commaIndices: [String.Index] = []
                    while cursor < source.endIndex && depth > 0 {
                        let ch = source[cursor]
                        if ch == "(" { depth += 1 }
                        else if ch == ")" { depth -= 1 }
                        else if ch == "," && depth == 1 {
                            commaIndices.append(cursor)
                        }
                        if depth > 0 {
                            cursor = source.index(after: cursor)
                        }
                    }
                    if let firstComma = commaIndices.first,
                       let lodComma = commaIndices.last,
                       firstComma != lodComma,
                       cursor < source.endIndex {
                        let argStart = source.index(index, offsetBy: needle.count)
                        // Recurse on uv/lod so a textureLod nested inside another
                        // textureLod's arguments is also rewritten (the sampler arg is
                        // always a plain identifier and cannot nest a call).
                        let sampler = source[argStart..<firstComma]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let uv = rewriteTextureLodCalls(
                            String(source[source.index(after: firstComma)..<lodComma]),
                            premultipliedInputSlots: premultipliedInputSlots,
                            repeatSamplers: repeatSamplers
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        let lod = rewriteTextureLodCalls(
                            String(source[source.index(after: lodComma)..<cursor]),
                            premultipliedInputSlots: premultipliedInputSlots,
                            repeatSamplers: repeatSamplers
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        let samplerState = repeatSamplers.contains(sampler) ? "repeatSampler" : "linearSampler"
                        var sample = "\(sampler).sample(\(samplerState), \(uv), level(\(lod)))"
                        if shouldUnpremultiplySample(sampler: sampler, premultipliedInputSlots: premultipliedInputSlots) {
                            sample = "wpe_unpremultiply_sample(\(sample))"
                        }
                        result += sample
                        index = source.index(after: cursor)
                        continue
                    }
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Rewrite `texture(<sampler>, <uv>)` calls (already canonicalised by the preprocessor) into Metal `<sampler>.sample(linearSampler, uv)` form.
    private static func rewriteTextureCalls(
        _ source: String,
        premultipliedInputSlots: Set<Int> = [],
        repeatSamplers: Set<String> = []
    ) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let needle = "texture("
        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                if priorOK {
                    var cursor = source.index(index, offsetBy: needle.count)
                    var depth = 1
                    var commaIndex: String.Index?
                    while cursor < source.endIndex && depth > 0 {
                        let ch = source[cursor]
                        if ch == "(" { depth += 1 }
                        else if ch == ")" { depth -= 1 }
                        else if ch == "," && depth == 1 && commaIndex == nil {
                            commaIndex = cursor
                        }
                        if depth > 0 {
                            cursor = source.index(after: cursor)
                        }
                    }
                    if let comma = commaIndex, cursor < source.endIndex {
                        let argStart = source.index(index, offsetBy: needle.count)
                        let sampler = source[argStart..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
                        let uv = source[source.index(after: comma)..<cursor].trimmingCharacters(in: .whitespacesAndNewlines)
                        let samplerState = repeatSamplers.contains(sampler) ? "repeatSampler" : "linearSampler"
                        var sample = "\(sampler).sample(\(samplerState), \(uv))"
                        if shouldUnpremultiplySample(sampler: sampler, premultipliedInputSlots: premultipliedInputSlots) {
                            sample = "wpe_unpremultiply_sample(\(sample))"
                        }
                        result += sample
                        index = source.index(after: cursor)
                        continue
                    }
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// A sampler slot bound to a premultiplied render target must be
    /// un-premultiplied before the shader's straight-alpha math runs.
    private static func shouldUnpremultiplySample(
        sampler: String,
        premultipliedInputSlots: Set<Int>
    ) -> Bool {
        guard !premultipliedInputSlots.isEmpty,
              let slot = textureSlot(for: sampler) else { return false }
        return premultipliedInputSlots.contains(slot)
    }

    // MARK: - Helper resource threading

    private struct HelperResource: Hashable {
        let name: String
        let parameterType: String
    }

    private struct HelperFunction {
        let name: String
        let parameterRange: Range<String.Index>
        let bodyRange: Range<String.Index>
    }

    /// Metal helper functions live outside `wpe_translated_fragment`, so they cannot see
    /// the sampler/uniform aliases emitted inside the fragment body. Thread those aliases
    /// through helper parameters and through helper call sites.
    private static func rewriteHelperResourceAccess(
        helpers: String,
        mainBody: String,
        uniforms: [WPEUniformDecl],
        samplers: [WPESamplerDecl],
        mutableGlobals: [ProgramScopeMutableDecl] = []
    ) -> (helpers: String, mainBody: String) {
        let functions = parseHelperFunctions(in: helpers)
        guard !functions.isEmpty else {
            return (helpers, mainBody)
        }

        let resources = helperResources(
            uniforms: uniforms,
            samplers: samplers,
            mutableGlobals: mutableGlobals
        )
        guard !resources.isEmpty else {
            return (helpers, mainBody)
        }
        let macroDependencies = helperMacroDependencies(in: helpers, resources: resources)

        let functionNames = Set(functions.map(\.name))
        var dependenciesByFunction: [String: Set<String>] = [:]
        var callsByFunction: [String: Set<String>] = [:]

        for function in functions {
            let body = String(helpers[function.bodyRange])
            // A function parameter shadows a like-named global uniform/sampler, so
            // a body reference resolves to the local — don't thread the global in
            // (it would duplicate the parameter and the MSL would be rejected, e.g.
            // tech_circle_barcode's `sectors(... float sectorCount, float seed)`).
            let shadowedNames = parameterNames(in: String(helpers[function.parameterRange]))
            var dependencies = Set(
                resources
                    .filter { containsIdentifier($0.name, in: body) && !shadowedNames.contains($0.name) }
                    .map(\.name)
            )
            for (macroName, macroResources) in macroDependencies where containsIdentifier(macroName, in: body) {
                dependencies.formUnion(macroResources)
            }
            dependencies.subtract(shadowedNames)
            dependenciesByFunction[function.name] = dependencies
            callsByFunction[function.name] = Set(
                functionNames.filter { callee in
                    callee != function.name && containsFunctionCall(callee, in: body)
                }
            )
        }

        var changed = true
        while changed {
            changed = false
            for function in functions {
                var dependencies = dependenciesByFunction[function.name] ?? []
                for callee in callsByFunction[function.name] ?? [] {
                    dependencies.formUnion(dependenciesByFunction[callee] ?? [])
                }
                if dependencies != dependenciesByFunction[function.name] {
                    dependenciesByFunction[function.name] = dependencies
                    changed = true
                }
            }
        }

        var rewrittenHelpers = helpers
        for function in functions.sorted(by: { $0.bodyRange.lowerBound > $1.bodyRange.lowerBound }) {
            let dependencies = dependenciesByFunction[function.name] ?? []
            let originalBody = String(rewrittenHelpers[function.bodyRange])
            rewrittenHelpers.replaceSubrange(
                function.bodyRange,
                with: rewriteHelperCalls(
                    in: originalBody,
                    dependenciesByFunction: dependenciesByFunction,
                    resourceOrder: resources
                )
            )

            guard !dependencies.isEmpty else { continue }
            let originalParameters = String(rewrittenHelpers[function.parameterRange])
            rewrittenHelpers.replaceSubrange(
                function.parameterRange,
                with: appendHelperParameters(
                    to: originalParameters,
                    dependencies: dependencies,
                    resourceOrder: resources
                )
            )
        }

        let rewrittenMain = rewriteHelperCalls(
            in: mainBody,
            dependenciesByFunction: dependenciesByFunction,
            resourceOrder: resources
        )
        return (rewrittenHelpers, rewrittenMain)
    }

    private static func helperResources(
        uniforms: [WPEUniformDecl],
        samplers: [WPESamplerDecl],
        mutableGlobals: [ProgramScopeMutableDecl] = []
    ) -> [HelperResource] {
        let samplerResources = samplers.map {
            HelperResource(name: $0.name, parameterType: "texture2d<float>")
        }
        let uniformResources = uniforms.map {
            HelperResource(name: $0.name, parameterType: helperParameterType(for: $0))
        }
        let mutableGlobalResources = mutableGlobals.map {
            HelperResource(name: $0.name, parameterType: $0.helperParameterType)
        }
        return samplerResources + uniformResources + mutableGlobalResources
    }

    private static func helperMacroDependencies(
        in source: String,
        resources: [HelperResource]
    ) -> [String: Set<String>] {
        let pattern = #"(?m)^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\b([^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var dependencies: [String: Set<String>] = [:]
        var bodies: [String: String] = [:]

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let bodyRange = Range(match.range(at: 2), in: source) else {
                continue
            }
            let name = String(source[nameRange])
            let body = String(source[bodyRange])
            bodies[name] = body
            dependencies[name] = Set(
                resources
                    .filter { containsIdentifier($0.name, in: body) }
                    .map(\.name)
            )
        }

        var changed = true
        while changed {
            changed = false
            for (macroName, body) in bodies {
                let current = dependencies[macroName] ?? []
                var merged = current
                for (callee, calleeDependencies) in dependencies where callee != macroName {
                    if containsIdentifier(callee, in: body) {
                        merged.formUnion(calleeDependencies)
                    }
                }
                if merged != current {
                    dependencies[macroName] = merged
                    changed = true
                }
            }
        }

        return dependencies
    }

    private static func helperParameterType(for uniform: WPEUniformDecl) -> String {
        if uniform.arrayLength != nil {
            switch uniform.type {
            case "vec2": return "thread const float2*"
            case "vec3": return "thread const float3*"
            case "vec4": return "thread const float4*"
            case "int":  return "thread const int*"
            case "bool": return "thread const bool*"
            default:     return "thread const float*"
            }
        }
        return uniform.metalType
    }

    private static func parseHelperFunctions(in source: String) -> [HelperFunction] {
        let pattern = #"(?m)(?:^|\n)\s*[A-Za-z_][A-Za-z0-9_<>,:&*\s]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var functions: [HelperFunction] = []

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: source),
                  let parametersRange = Range(match.range(at: 2), in: source),
                  let matchRange = Range(match.range, in: source) else {
                continue
            }
            let openBrace = source.index(before: matchRange.upperBound)
            guard source[openBrace] == "{",
                  let closeBrace = matchingDelimiter(in: source, open: openBrace, openChar: "{", closeChar: "}") else {
                continue
            }
            let bodyRange = source.index(after: openBrace)..<closeBrace
            functions.append(HelperFunction(
                name: String(source[nameRange]),
                parameterRange: parametersRange,
                bodyRange: bodyRange
            ))
        }

        return functions
    }

    private static func rewriteHelperCalls(
        in source: String,
        dependenciesByFunction: [String: Set<String>],
        resourceOrder: [HelperResource]
    ) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex

        while index < source.endIndex {
            let ch = source[index]
            guard isIdentifierStart(ch) else {
                result.append(ch)
                index = source.index(after: index)
                continue
            }

            let identifierStart = index
            var identifierEnd = source.index(after: index)
            while identifierEnd < source.endIndex,
                  isIdentifierCharacter(source[identifierEnd]) {
                identifierEnd = source.index(after: identifierEnd)
            }

            let name = String(source[identifierStart..<identifierEnd])
            var cursor = identifierEnd
            while cursor < source.endIndex && source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }

            if let dependencies = dependenciesByFunction[name],
               !dependencies.isEmpty,
               cursor < source.endIndex,
               source[cursor] == "(",
               let closeParen = matchingDelimiter(in: source, open: cursor, openChar: "(", closeChar: ")") {
                let argumentsRange = source.index(after: cursor)..<closeParen
                let rewrittenArguments = rewriteHelperCalls(
                    in: String(source[argumentsRange]),
                    dependenciesByFunction: dependenciesByFunction,
                    resourceOrder: resourceOrder
                )
                result += source[identifierStart..<cursor]
                result += "("
                result += appendHelperCallArguments(
                    to: rewrittenArguments,
                    dependencies: dependencies,
                    resourceOrder: resourceOrder
                )
                result += ")"
                index = source.index(after: closeParen)
                continue
            }

            result += source[identifierStart..<identifierEnd]
            index = identifierEnd
        }

        return result
    }

    /// Extracts declared parameter names from a function parameter list
    /// (e.g. `"float pos, vec2 puv, float sectorCount"` -> `["pos","puv","sectorCount"]`).
    /// The name is the trailing identifier of each comma-separated declaration.
    private static func parameterNames(in parameters: String) -> Set<String> {
        let trimmed = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "void" else { return [] }
        var names = Set<String>()
        for parameter in trimmed.split(separator: ",") {
            let tokens = parameter.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            guard let last = tokens.last else { continue }
            // Stop at the first non-identifier char so array params like `arr[4]`
            // and qualified names resolve to the bare identifier.
            let name = last.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    private static func appendHelperParameters(
        to parameters: String,
        dependencies: Set<String>,
        resourceOrder: [HelperResource]
    ) -> String {
        let additions = orderedResources(dependencies, resourceOrder: resourceOrder)
            .map { "\($0.parameterType) \($0.name)" }
            .joined(separator: ", ")
        let trimmed = parameters.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "void" {
            return additions
        }
        return "\(parameters), \(additions)"
    }

    private static func appendHelperCallArguments(
        to arguments: String,
        dependencies: Set<String>,
        resourceOrder: [HelperResource]
    ) -> String {
        let additions = orderedResources(dependencies, resourceOrder: resourceOrder)
            .map(\.name)
            .joined(separator: ", ")
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "void" {
            return additions
        }
        return "\(arguments), \(additions)"
    }

    private static func orderedResources(
        _ dependencies: Set<String>,
        resourceOrder: [HelperResource]
    ) -> [HelperResource] {
        resourceOrder.filter { dependencies.contains($0.name) }
    }

    private static func containsFunctionCall(_ name: String, in source: String) -> Bool {
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index...].hasPrefix(name),
                  identifierBoundary(before: index, in: source) else {
                index = source.index(after: index)
                continue
            }
            let afterName = source.index(index, offsetBy: name.count)
            guard identifierBoundary(after: afterName, in: source) else {
                index = source.index(after: index)
                continue
            }
            var cursor = afterName
            while cursor < source.endIndex && source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }
            if cursor < source.endIndex && source[cursor] == "(" {
                return true
            }
            index = source.index(after: index)
        }
        return false
    }

    private static func containsIdentifier(_ name: String, in source: String) -> Bool {
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index...].hasPrefix(name),
                  identifierBoundary(before: index, in: source) else {
                index = source.index(after: index)
                continue
            }
            let afterName = source.index(index, offsetBy: name.count)
            if identifierBoundary(after: afterName, in: source) {
                return true
            }
            index = source.index(after: index)
        }
        return false
    }

    private static func matchingDelimiter(
        in source: String,
        open: String.Index,
        openChar: Character,
        closeChar: Character
    ) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            let ch = source[index]
            if ch == openChar {
                depth += 1
            } else if ch == closeChar {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func identifierBoundary(before index: String.Index, in source: String) -> Bool {
        guard index > source.startIndex else { return true }
        return !isIdentifierCharacter(source[source.index(before: index)])
    }

    private static func identifierBoundary(after index: String.Index, in source: String) -> Bool {
        guard index < source.endIndex else { return true }
        return !isIdentifierCharacter(source[index])
    }

    private static func isIdentifierStart(_ ch: Character) -> Bool {
        ch == "_" || ch.isLetter
    }

    private static func isIdentifierCharacter(_ ch: Character) -> Bool {
        ch == "_" || ch.isLetter || ch.isNumber
    }

    // MARK: - Render

    /// Emit the final MSL source with the fixed parameter signature so the dispatcher knows what to bind without doing runtime reflection.
    private static func renderMSL(
        shaderName: String,
        uniforms: [WPEUniformDecl],
        samplers: [WPESamplerDecl],
        varyings: [WPEVaryingDecl],
        helpers: String,
        mainBody: String,
        mutableGlobals: [ProgramScopeMutableDecl] = [],
        comboValues: [String: Int] = [:],
        premultipliedInputSlots: Set<Int> = [],
        premultipliedOutput: Bool = false
    ) -> String {
        let warningCleanHelpers = neutralizeMetalStdlibMacroRedefinitions(helpers)
        let warningCleanMainBody = neutralizeMetalStdlibMacroRedefinitions(mainBody)
        var out: [String] = [
            "#include <metal_stdlib>",
            "using namespace metal;",
            "",
            "// Generated by WPEShaderTranspiler from \(shaderName).",
            ""
        ]

        out.append("struct WPEStageIn {")
        out.append("    float4 position [[position]];")
        out.append("    float2 uv;")
        out.append("};")
        out.append("")

        if !uniforms.isEmpty {
            // Size to this shader's own slot count, not `uniformSlotMaximum`: the host binds exactly
            // `totalSlots × 16` bytes, and Metal validation rejects a buffer shorter than the struct.
            let totalSlots = uniforms.reduce(0) { $0 + ($1.arrayLength ?? slotCount(for: $1.type)) }
            out.append("struct WPEUniforms {")
            out.append("    float4 vals[\(max(totalSlots, 1))];")
            out.append("};")
            out.append("")
        }

        out.append("[[maybe_unused]] constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);")
        out.append("[[maybe_unused]] constexpr sampler repeatSampler(address::repeat, filter::linear);")
        out.append("inline float min(int lhs, float rhs) { return metal::min(float(lhs), rhs); }")
        out.append("inline float min(float lhs, int rhs) { return metal::min(lhs, float(rhs)); }")
        out.append("inline float max(int lhs, float rhs) { return metal::max(float(lhs), rhs); }")
        out.append("inline float max(float lhs, int rhs) { return metal::max(lhs, float(rhs)); }")
        out.append("inline float clamp(int value, float lower, float upper) { return metal::clamp(float(value), lower, upper); }")
        out.append("inline float clamp(float value, int lower, float upper) { return metal::clamp(value, float(lower), upper); }")
        out.append("inline float clamp(float value, float lower, int upper) { return metal::clamp(value, lower, float(upper)); }")
        out.append("inline float clamp(int value, int lower, float upper) { return metal::clamp(float(value), float(lower), upper); }")
        out.append("inline float clamp(int value, float lower, int upper) { return metal::clamp(float(value), lower, float(upper)); }")
        out.append("inline float clamp(float value, int lower, int upper) { return metal::clamp(value, float(lower), float(upper)); }")
        out.append("inline float wpe_smoothstep(float edge0, float edge1, float x) {")
        out.append("    float width = edge1 - edge0;")
        out.append("    if (abs(width) <= 1.0e-7) { return x < edge0 ? 0.0 : 1.0; }")
        out.append("    float t = metal::clamp((x - edge0) / width, 0.0, 1.0);")
        out.append("    return t * t * (3.0 - 2.0 * t);")
        out.append("}")
        out.append("inline float2 wpe_smoothstep(float2 edge0, float2 edge1, float2 x) { return float2(wpe_smoothstep(edge0.x, edge1.x, x.x), wpe_smoothstep(edge0.y, edge1.y, x.y)); }")
        out.append("inline float3 wpe_smoothstep(float3 edge0, float3 edge1, float3 x) { return float3(wpe_smoothstep(edge0.x, edge1.x, x.x), wpe_smoothstep(edge0.y, edge1.y, x.y), wpe_smoothstep(edge0.z, edge1.z, x.z)); }")
        out.append("inline float4 wpe_smoothstep(float4 edge0, float4 edge1, float4 x) { return float4(wpe_smoothstep(edge0.x, edge1.x, x.x), wpe_smoothstep(edge0.y, edge1.y, x.y), wpe_smoothstep(edge0.z, edge1.z, x.z), wpe_smoothstep(edge0.w, edge1.w, x.w)); }")
        out.append("inline float2 wpe_smoothstep(float edge0, float edge1, float2 x) { return wpe_smoothstep(float2(edge0), float2(edge1), x); }")
        out.append("inline float3 wpe_smoothstep(float edge0, float edge1, float3 x) { return wpe_smoothstep(float3(edge0), float3(edge1), x); }")
        out.append("inline float4 wpe_smoothstep(float edge0, float edge1, float4 x) { return wpe_smoothstep(float4(edge0), float4(edge1), x); }")
        if !premultipliedInputSlots.isEmpty {
            // Recover straight-alpha color from a premultiplied render-target
            // sample so the original WPE shader math operates in straight space.
            out.append("inline float4 wpe_unpremultiply_sample(float4 color) {")
            out.append("    float a = color.a;")
            out.append("    color.rgb = a > 0.00001 ? color.rgb / a : float3(0.0);")
            out.append("    return color;")
            out.append("}")
        }
        if premultipliedOutput {
            // Premultiply the shader's straight-alpha output for the
            // premultiplied render-target pipeline.
            out.append("inline float4 wpe_premultiply_output(float4 color) {")
            out.append("    float a = metal::clamp(color.a, 0.0, 1.0);")
            out.append("    return float4(color.rgb * a, a);")
            out.append("}")
        }
        appendCompatibilityPrelude(to: &out, helpers: warningCleanHelpers)
        out.append("")

        if !warningCleanHelpers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(warningCleanHelpers)
            out.append("")
        }

        var signature = ["fragment float4 wpe_translated_fragment("]
        signature.append("    WPEStageIn in [[stage_in]],")
        if !uniforms.isEmpty {
            signature.append("    constant WPEUniforms& u [[buffer(0)]],")
        }
        for slot in 0..<Self.customTextureSlotCount {
            let comma = slot < Self.customTextureSlotCount - 1 ? "," : ""
            signature.append("    texture2d<float> tex\(slot) [[texture(\(slot))]]\(comma)")
        }
        signature.append(") {")
        out.append(signature.joined(separator: "\n"))

        // Alias each sampler to its ACTUAL texture slot (`g_Texture2` → tex2),
        // matching how the custom-shader dispatcher binds textures
        // (`setFragmentTexture(index: slot)`). Enumeration order would mis-map
        // any sparse / non-zero slot (`g_Texture2` → tex0) and sample the wrong
        // texture. Non-`g_TextureN` samplers (no parsed slot) keep enumeration
        // order as before.
        for (index, sampler) in samplers.enumerated() {
            let slot = Self.textureSlot(for: sampler.name) ?? index
            out.append("    [[maybe_unused]] auto \(sampler.name) = tex\(slot);")
        }
        var slotCursor = 0
        for u in uniforms {
            if let arrayLength = u.arrayLength {
                let elementType: String
                switch u.type {
                case "vec2": elementType = "float2"
                case "vec3": elementType = "float3"
                case "vec4": elementType = "float4"
                case "int":  elementType = "int"
                case "bool": elementType = "bool"
                default:     elementType = "float"
                }
                out.append("    [[maybe_unused]] \(elementType) \(u.name)[\(arrayLength)];")
                for i in 0..<arrayLength {
                    let read: String
                    switch elementType {
                    case "float2": read = "u.vals[\(slotCursor + i)].xy"
                    case "float3": read = "u.vals[\(slotCursor + i)].xyz"
                    case "float4": read = "u.vals[\(slotCursor + i)]"
                    case "int":    read = "int(u.vals[\(slotCursor + i)].x)"
                    case "bool":   read = "u.vals[\(slotCursor + i)].x > 0.5"
                    default:       read = "u.vals[\(slotCursor + i)].x"
                    }
                    out.append("    \(u.name)[\(i)] = \(read);")
                }
                slotCursor += arrayLength
                continue
            }
            let slots = Self.slotCount(for: u.type)
            switch u.type {
            case "float":
                out.append("    [[maybe_unused]] float \(u.name) = u.vals[\(slotCursor)].x;")
            case "vec2":
                out.append("    [[maybe_unused]] float2 \(u.name) = u.vals[\(slotCursor)].xy;")
            case "vec3":
                out.append("    [[maybe_unused]] float3 \(u.name) = u.vals[\(slotCursor)].xyz;")
            case "vec4":
                out.append("    [[maybe_unused]] float4 \(u.name) = u.vals[\(slotCursor)];")
            case "int":
                out.append("    [[maybe_unused]] int \(u.name) = int(u.vals[\(slotCursor)].x);")
            case "ivec2":
                out.append("    [[maybe_unused]] int2 \(u.name) = int2(u.vals[\(slotCursor)].xy);")
            case "ivec3":
                out.append("    [[maybe_unused]] int3 \(u.name) = int3(u.vals[\(slotCursor)].xyz);")
            case "ivec4":
                out.append("    [[maybe_unused]] int4 \(u.name) = int4(u.vals[\(slotCursor)]);")
            case "bool":
                out.append("    [[maybe_unused]] bool \(u.name) = u.vals[\(slotCursor)].x > 0.5;")
            case "bvec2":
                out.append("    [[maybe_unused]] bool2 \(u.name) = u.vals[\(slotCursor)].xy > float2(0.5);")
            case "bvec3":
                out.append("    [[maybe_unused]] bool3 \(u.name) = u.vals[\(slotCursor)].xyz > float3(0.5);")
            case "bvec4":
                out.append("    [[maybe_unused]] bool4 \(u.name) = u.vals[\(slotCursor)] > float4(0.5);")
            case "mat2":
                out.append("    [[maybe_unused]] float2x2 \(u.name) = float2x2(u.vals[\(slotCursor)].xy, u.vals[\(slotCursor + 1)].xy);")
            case "mat3":
                out.append("    [[maybe_unused]] float3x3 \(u.name) = float3x3(u.vals[\(slotCursor)].xyz, u.vals[\(slotCursor + 1)].xyz, u.vals[\(slotCursor + 2)].xyz);")
            case "mat4":
                out.append("    [[maybe_unused]] float4x4 \(u.name) = float4x4(u.vals[\(slotCursor)], u.vals[\(slotCursor + 1)], u.vals[\(slotCursor + 2)], u.vals[\(slotCursor + 3)]);")
            default:
                out.append("    [[maybe_unused]] \(u.metalType) \(u.name) = u.vals[\(slotCursor)].x;")
            }
            slotCursor += slots
        }

        let uniformNames = Set(uniforms.map(\.name))
        let autoSwayReconstruction = autoSwayVaryingReconstructionLines(
            varyings: varyings,
            availableUniforms: uniformNames,
            comboValues: comboValues
        )
        // Screen-UV fallbacks produced when no reconstruction rule matched a varying.
        // A non-v_TexCoord varying that the fragment actually uses but lands here renders
        // incorrectly (a 0→1 UV ramp standing in for vertex-computed data) — emit a marker
        // in the generated MSL so the gap is visible in scene-debug dumps instead of silent.
        let uvFallbackInitializers: Set<String> = [
            "in.uv", "in.uv.x", "float4(in.uv, in.uv)", "float3(in.uv, 0.0)",
        ]
        for varying in varyings {
            if varying.name == "uv" { continue }
            let initializer = varyingInitializer(
                for: varying,
                shaderName: shaderName,
                availableUniforms: uniformNames,
                comboValues: comboValues
            )
            if varying.name != "v_TexCoord",
               uvFallbackInitializers.contains(initializer),
               !autoSwayReconstruction.contains(where: { $0.contains(" \(varying.name) = ") }),
               warningCleanMainBody.range(of: "\\b\(NSRegularExpression.escapedPattern(for: varying.name))\\b", options: .regularExpression) != nil {
                out.append("    // WPE-DIAGNOSTIC: varying '\(varying.name)' has no reconstruction rule and fell back to a screen-UV default; this likely renders incorrectly.")
            }
            if let arrayLength = varying.arrayLength {
                let initializers = Array(repeating: initializer, count: arrayLength).joined(separator: ", ")
                out.append("    [[maybe_unused]] \(varying.metalType) \(varying.name)[\(arrayLength)] = { \(initializers) };")
            } else if let arrayDimension = varying.arrayDimension {
                // Symbolic, #define-sized array: we can't expand a literal initializer list at
                // transpile time, so zero-init, then let known vertex-varying reconstructions
                // fill the slots they need.
                out.append("    [[maybe_unused]] \(varying.metalType) \(varying.name)[\(arrayDimension)] = {};")
                out.append(
                    contentsOf: symbolicArrayReconstructionLines(
                        for: varying,
                        availableUniforms: uniformNames,
                        comboValues: comboValues
                    )
                )
            } else {
                out.append("    [[maybe_unused]] \(varying.metalType) \(varying.name) = \(initializer);")
            }
        }

        for declaration in mutableGlobals {
            out.append("    [[maybe_unused]] \(declaration.metalType) \(declaration.name) = \(declaration.initializer);")
        }

        out.append(contentsOf: autoSwayReconstruction)

        out.append("    {")
        out.append(warningCleanMainBody)
        out.append("    }")
        out.append("}")
        return out.joined(separator: "\n")
    }

    /// Fragment-side reconstruction of `auto_sway.vert` (workshop 3235948233,
    /// `AA_VERSION == 2`) — the per-node sway state the fragment consumes. All
    /// of it is uniform-only except the `v_PosX`/`v_EndpointPosX` dot products,
    /// which are affine in the texcoord and therefore identical when recomputed
    /// per-pixel from the interpolated UV. Without this the varyings fell back
    /// to screen-UV ramps and the swaying hair locks smeared across the layer
    /// (3462491575: bangs rotated over the eyes on both characters).
    /// Matched structurally (v2 varying signature + the shader's distinctive
    /// uniforms) so repacks under other workshop IDs reconstruct too; the v1/v3
    /// variants keep today's fallback.
    private static func autoSwayVaryingReconstructionLines(
        varyings: [WPEVaryingDecl],
        availableUniforms: Set<String>,
        comboValues: [String: Int]
    ) -> [String] {
        let varyingNames = Set(varyings.map(\.name))
        guard varyingNames.contains("v_MotionRadian1"),
              varyingNames.contains("v_EndpointDirection1"),
              varyingNames.contains("v_TexCoord"),
              varyingNames.contains("v_aspect"),
              hasUniforms(
                "g_SpinCenter1", "g_SpinCenter2", "g_WindDirection2",
                "g_Inertia", "g_SigmentCount", "g_Speed", "g_GlobalTimeOffset",
                "g_GlobalWindOffset", "g_Time", "g_Texture0Resolution",
                "g_SmoothDistance", "g_DirectionalCompensation",
                in: availableUniforms
              ) else {
            return []
        }
        let nodeCount = min(max(comboValues["NODE_COUNT"] ?? 2, 2), 11)
        let autoTimeoffset = (comboValues["AUTO_TIMEOFFSET"] ?? 1) == 1
        let interpolation = comboValues["AUTO_TIMEOFFSET_INTERPOLATION"] ?? 0
        let usesExponent = (comboValues["EXPONENT"] ?? 0) == 1 && availableUniforms.contains("g_Exponent")
        let usesNoise = (comboValues["NOISE"] ?? 0) == 1
            && hasUniforms("g_NoiseSpeed", "g_Friction", "g_NoiseAmount", in: availableUniforms)
        let halfPi = "1.5707963267948966"

        // `linearStep` & friends over compile-time constants (lower=2,
        // upper=NODE_COUNT, x=nodeNum): fold to a literal. Division by a zero
        // span mirrors D3D saturate: 0/0 (NaN) → 0, k/0 (+inf) → 1.
        func stepValue(_ x: Double) -> Double {
            let span = Double(nodeCount) - 2
            let raw = (x - 2) / span
            let t = raw.isNaN ? 0 : min(max(raw, 0), 1)
            switch interpolation {
            case 1: return pow(t, 3)
            case 2: return pow(t, 4)
            case 3: return pow(t, 5)
            case 4: return 1 - (1 - pow(t, 2)).squareRoot()
            case 5: return 1 - cos(t * Double.pi * 0.5)
            case 6: return 1 - pow(1 - t, 3)
            case 7: return 1 - pow(1 - t, 4)
            case 8: return 1 - pow(1 - t, 5)
            case 9: return (1 - pow(t - 1, 2)).squareRoot()
            case 10: return sin(t * Double.pi * 0.5)
            default: return t
            }
        }

        var lines: [String] = []
        lines.append("    // auto_sway v2 vertex-stage state, reconstructed per-pixel (uniform-only + UV-affine).")
        lines.append("    v_aspect = g_Texture0Resolution.z / g_Texture0Resolution.w;")
        if varyingNames.contains("v_reciprocalAspect") {
            lines.append("    v_reciprocalAspect = 1.0 / v_aspect;")
        }
        lines.append("    v_TexCoord = float4(in.uv.x * v_aspect, in.uv.y, in.uv.x * v_aspect, in.uv.y);")
        lines.append("    {")
        lines.append("        float2 wpeAS_endpointC = float2(g_SpinCenter1.x * v_aspect, g_SpinCenter1.y);")
        lines.append("        float wpeAS_baseTime = g_GlobalTimeOffset + g_Time * g_Speed;")
        if autoTimeoffset {
            lines.append("        float wpeAS_motionOffset = g_Inertia * g_SigmentCount;")
        }
        if usesNoise {
            lines.append("        float2 wpeAS_friction = g_Friction;")
        }

        for node in 2...nodeCount {
            let i = node - 1
            let requiredVaryings = [
                "v_Direction\(i)", "v_EndpointDirection\(i)", "v_Len\(i)",
                "v_EndpointLen\(i)", "v_PosX\(i)", "v_EndpointPosX\(i)", "v_MotionRadian\(i)",
            ]
            guard requiredVaryings.allSatisfy(varyingNames.contains),
                  hasUniforms("g_SpinCenter\(node - 1)", "g_SpinCenter\(node)", "g_WindDirection\(node)", in: availableUniforms) else {
                continue
            }
            let nextWind = node == 11 ? halfPi
                : (availableUniforms.contains("g_WindDirection\(node + 1)") ? "g_WindDirection\(node + 1)" : "\(halfPi)")
            let thisTimeTerm: String
            let prevTimeTerm: String
            if autoTimeoffset {
                thisTimeTerm = "wpeAS_motionOffset * \(stepValue(Double(node)))"
                prevTimeTerm = "wpeAS_motionOffset * \(stepValue(Double(node + 1)))"
            } else {
                thisTimeTerm = availableUniforms.contains("g_TimeOffset\(node - 1)") ? "g_TimeOffset\(node - 1)" : "0.0"
                prevTimeTerm = node == 11 ? "0.0"
                    : (availableUniforms.contains("g_TimeOffset\(node)") ? "g_TimeOffset\(node)" : "0.0")
            }
            lines.append("        {")
            lines.append("            float2 wpeAS_thisC = float2(g_SpinCenter\(node - 1).x * v_aspect, g_SpinCenter\(node - 1).y);")
            lines.append("            float2 wpeAS_nextC = float2(g_SpinCenter\(node).x * v_aspect, g_SpinCenter\(node).y);")
            lines.append("            float2 wpeAS_nodeVec = wpeAS_thisC - wpeAS_nextC;")
            lines.append("            float2 wpeAS_eNodeVec = wpeAS_endpointC - wpeAS_nextC;")
            lines.append("            v_Direction\(i) = wpe_safe_normalize(wpeAS_nodeVec);")
            lines.append("            v_EndpointDirection\(i) = mix(wpe_safe_normalize(wpeAS_eNodeVec), v_Direction\(i), g_DirectionalCompensation);")
            lines.append("            v_Len\(i) = dot(wpeAS_nodeVec, v_Direction\(i));")
            lines.append("            v_EndpointLen\(i) = mix(v_Len\(i), dot(wpeAS_eNodeVec, v_EndpointDirection\(i)), g_SmoothDistance);")
            lines.append("            float2 wpeAS_relTC = v_TexCoord.zw - wpeAS_nextC;")
            lines.append("            v_EndpointPosX\(i) = dot(wpeAS_relTC, v_EndpointDirection\(i));")
            lines.append("            v_PosX\(i) = v_EndpointPosX\(i);")
            lines.append("            float wpeAS_thisT = wpeAS_baseTime + \(thisTimeTerm);")
            lines.append("            float wpeAS_prevT = wpeAS_baseTime + \(prevTimeTerm);")
            lines.append("            float wpeAS_thisRad = sin(wpeAS_thisT * \(halfPi));")
            lines.append("            float wpeAS_prevRad = sin(wpeAS_prevT * \(halfPi)) * g_Inertia;")
            if usesExponent {
                lines.append("            wpeAS_thisRad = sign(wpeAS_thisRad) * pow(abs(wpeAS_thisRad), g_Exponent);")
                lines.append("            wpeAS_prevRad = sign(wpeAS_prevRad) * pow(abs(wpeAS_prevRad), g_Exponent);")
            }
            lines.append("            wpeAS_thisRad += sin(g_WindDirection\(node) + \(halfPi)) + sin(g_GlobalWindOffset);")
            lines.append("            wpeAS_prevRad += sin(\(nextWind) + \(halfPi));")
            if usesNoise {
                for (radVar, timeVar) in [("wpeAS_thisRad", "wpeAS_thisT"), ("wpeAS_prevRad", "wpeAS_prevT")] {
                    lines.append("            {")
                    lines.append("                float4 wpeAS_sines = fract(g_NoiseSpeed * \(timeVar) / \(halfPi) * float4(1.0, -0.16161616, 0.0083333, -0.00019841)) * \(halfPi);")
                    lines.append("                float4 wpeAS_csines = cos(wpeAS_sines);")
                    lines.append("                wpeAS_sines = sin(wpeAS_sines);")
                    lines.append("                float4 wpeAS_base = step(float4(0.0), wpeAS_csines);")
                    lines.append("                wpeAS_sines = wpeAS_sines * 0.498 + 0.5;")
                    lines.append("                wpeAS_sines = mix(1.0 - pow(1.0 - wpeAS_sines, float4(wpeAS_friction.x)), pow(wpeAS_sines, float4(wpeAS_friction.y)), wpeAS_base);")
                    lines.append("                \(radVar) += (dot(float4(0.5), wpeAS_sines) - 1.0) * g_NoiseAmount;")
                    lines.append("            }")
                }
            }
            lines.append("            v_MotionRadian\(i) = wpeAS_thisRad - wpeAS_prevRad;")
            lines.append("        }")
        }
        lines.append("    }")
        return lines
    }

    private static let metalStdlibMacroDefinitions: Set<String> = [
        "M_PI_F"
    ]

    private static func neutralizeMetalStdlibMacroRedefinitions(_ source: String) -> String {
        guard source.contains("#") else { return source }
        return source.components(separatedBy: "\n").map { line in
            guard let macroName = defineMacroName(in: line),
                  metalStdlibMacroDefinitions.contains(macroName) else {
                return line
            }
            return "// disabled duplicate Metal stdlib macro definition: \(macroName)"
        }.joined(separator: "\n")
    }

    private static func defineMacroName(in line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "#" else { return nil }
        trimmed.removeFirst()

        let directive = trimmed.trimmingCharacters(in: .whitespaces)
        guard directive.hasPrefix("define") else { return nil }

        let afterDirective = directive.dropFirst("define".count)
        guard afterDirective.first?.isWhitespace == true else { return nil }
        let afterWhitespace = afterDirective.drop(while: { $0.isWhitespace })
        guard let first = afterWhitespace.first, isIdentifierStart(first) else { return nil }

        var name = ""
        for ch in afterWhitespace {
            guard isIdentifierCharacter(ch) else { break }
            name.append(ch)
        }
        return name
    }

    private static func appendCompatibilityPrelude(to out: inout [String], helpers: String) {
        let existingFunctionNames = Set(parseHelperFunctions(in: helpers).map(\.name))

        if !existingFunctionNames.contains("mod") {
            out.append("inline float mod(float x, float y) { return x - y * floor(x / y); }")
            out.append("inline float mod(float x, int y) { return mod(x, float(y)); }")
            out.append("inline float2 mod(float2 x, float2 y) { return x - y * floor(x / y); }")
            out.append("inline float2 mod(float2 x, float y) { return mod(x, float2(y)); }")
            out.append("inline float2 mod(float2 x, int y) { return mod(x, float(y)); }")
            out.append("inline float3 mod(float3 x, float3 y) { return x - y * floor(x / y); }")
            out.append("inline float3 mod(float3 x, float y) { return mod(x, float3(y)); }")
            out.append("inline float3 mod(float3 x, int y) { return mod(x, float(y)); }")
            out.append("inline float4 mod(float4 x, float4 y) { return x - y * floor(x / y); }")
            out.append("inline float4 mod(float4 x, float y) { return mod(x, float4(y)); }")
            out.append("inline float4 mod(float4 x, int y) { return mod(x, float(y)); }")
        }

        if !existingFunctionNames.contains("greyscale") {
            out.append("inline float greyscale(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }")
            out.append("inline float greyscale(float4 c) { return greyscale(c.rgb); }")
        }

        if !existingFunctionNames.contains("rgb2hsv") {
            out.append(
                """
                inline float3 rgb2hsv(float3 c) {
                    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
                    float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
                    float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
                    float d = q.x - min(q.w, q.y);
                    float e = 1.0e-10;
                    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
                }
                """
            )
        }

        if !existingFunctionNames.contains("hsv2rgb") {
            out.append(
                """
                inline float3 hsv2rgb(float3 c) {
                    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
                    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
                    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
                }
                """
            )
        }

        if !existingFunctionNames.contains("DecompressNormal") {
            out.append(
                """
                inline float3 DecompressNormal(float4 packed) {
                    float2 nxy = packed.xy * 2.0 - 1.0;
                    float nz = sqrt(max(0.0, 1.0 - dot(nxy, nxy)));
                    return float3(nxy, nz);
                }
                """
            )
            out.append("inline float3 DecompressNormal(float3 packed) { return DecompressNormal(float4(packed, 0.0)); }")
        }

        out.append(
            """
            inline float wpe_safe_ratio(float numerator, float denominator) {
                return abs(denominator) > 0.000001 ? numerator / denominator : 0.0;
            }
            inline float2 wpe_rotate_vec2(float2 v, float angle) {
                float c = cos(angle);
                float s = sin(angle);
                return float2(c * v.x - s * v.y, s * v.x + c * v.y);
            }
            inline float2 wpe_safe_normalize(float2 v) {
                float len = length(v);
                return len > 1e-8 ? v / len : float2(0.0, 1.0);
            }
            inline float2 wpe_scroll_vector(float scrollX, float scrollY, float time) {
                float2 scroll = float2(scrollX, scrollY);
                return sign(scroll) * pow(abs(scroll), float2(2.0)) * time;
            }
            inline float4 wpe_texcoord_with_resolution(float2 uv, float4 resolution) {
                float2 scale = float2(
                    wpe_safe_ratio(resolution.z, resolution.x),
                    wpe_safe_ratio(resolution.w, resolution.y)
                );
                return float4(uv, uv * scale);
            }
            inline float4 wpe_texcoord_mask(float2 uv, float4 resolution) {
                float2 scale = float2(
                    wpe_safe_ratio(resolution.z, resolution.x),
                    wpe_safe_ratio(resolution.w, resolution.y)
                );
                return float4(uv * scale, scale);
            }
            inline float4 wpe_ripple_texcoord(float2 uv, float time, float animationSpeed, float scrollSpeed, float direction, float ratio, float scale, float4 texture0Resolution) {
                float animation = time * animationSpeed * animationSpeed;
                float2 scroll = wpe_rotate_vec2(float2(0.0, 1.0), direction) * scrollSpeed * scrollSpeed * time;
                float4 ripple = float4(uv + animation + scroll, uv * 1.333 - animation + scroll) * scale;
                ripple.xz *= wpe_safe_ratio(texture0Resolution.x, texture0Resolution.y);
                ripple.yw *= ratio;
                return ripple;
            }
            inline float2 wpe_iris_texcoord(float timeUniform, float speed, float phaseOffset, float rough, float noiseAmount, float2 scale) {
                float time = timeUniform * speed + phaseOffset;
                float lowDt = floor(time);
                float2 motion2 = sin(1.9 * (lowDt + float2(0.0, 1.0)));
                float4 motion4 = sin(2.5 * (lowDt + float4(0.0, 0.0, 1.0, 1.0)) + float4(1.0, 2.0, 1.0, 2.0));
                float2 moveStart = motion2.xx + motion4.xy;
                float2 moveEnd = motion2.yy + motion4.zw;
                float eased = wpe_smoothstep(1.0 - rough, 1.0, cos(fract(time) * 3.14159265359) * -0.5 + 0.5);
                float2 da = mix(moveStart, moveEnd, eased);
                da.x += sin(time) * noiseAmount;
                da.y += cos(time) * noiseAmount;
                return da * scale * 0.001;
            }
            inline float wpe_foliage_aspect(float4 texture0Resolution, float ratio) {
                float aspect = wpe_safe_ratio(texture0Resolution.z, texture0Resolution.w) * ratio;
                return abs(aspect) > 0.000001 ? aspect : 1.0;
            }
            inline float4 wpe_foliage_texcoord_noise(float2 uv, float noiseScale, float ratio, float direction, float4 texture0Resolution) {
                float aspect = wpe_foliage_aspect(texture0Resolution, ratio);
                return float4(uv * noiseScale, wpe_rotate_vec2(float2(1.0 / aspect, aspect), direction));
            }
            inline float3 wpe_foliage_params(float2 uv, float direction, float strength) {
                return float3(wpe_rotate_vec2(uv, direction), strength * strength * 0.005);
            }
            // filmgrain.vert's v_TexCoordNoise: two noise lookups scrolled by frac(time)
            // and tiled by g_NoiseScale (aspect-corrected on x). Distinct from the foliage
            // variant above — without it the varying fell back to raw uv, sampling the
            // 256² noise once across the whole frame (smooth blotches soft-light blended
            // over everything = a static "retro filter") instead of fine animated grain.
            inline float4 wpe_filmgrain_texcoord_noise(float2 uv, float time, float scale, float4 texture0Resolution) {
                float t = fract(time);
                float aspect = wpe_safe_ratio(texture0Resolution.z, texture0Resolution.w);
                float4 coords = float4((uv + t) * scale, (uv - t * 2.5) * scale * 0.52);
                return coords * float4(aspect, 1.0, aspect, 1.0);
            }
            inline float2 wpe_bounds_vector(float2 bounds) {
                return float2(bounds.x, 1.0 / max(bounds.y - bounds.x, 0.000001));
            }
            // pulse.vert's non-audio `v_Pulse`: a time-driven sine gated through
            // g_PulseThresholds, scaled by g_PulseAmount (0 at rest, pulses over time).
            // Without it the float varying defaulted to `in.uv.x` — a left-to-right
            // brightness/alpha ramp instead of a uniform full-screen pulse.
            inline float wpe_pulse_response(float time, float2 thresholds, float speed, float phase, float amount) {
                float wave = sin(time * speed + (phase - 0.25) * 6.28318530717958647692) * 0.5 + 0.5;
                return wpe_smoothstep(thresholds.x, thresholds.y, wave) * amount;
            }
            // Vertex-stage `v_AudioShift` (WPE common.h CreateAudioResponse): the
            // FFT bins in [freqMin, freqMax] are averaged, smoothstepped against
            // g_AudioBounds, raised to g_AudioPower and scaled by g_AudioMultiply.
            // `mode` is the AUDIOPROCESSING combo (1=left, 2=right, 3=both). Returns
            // 0 when silent — matching WPE, where the effect rests until audio plays.
            // The fragment-only transpile has no vertex stage, so without this the
            // varying defaulted to `in.uv.x`, smearing the whole frame (chromatic
            // aberration / hue_shift glitch across the screen even with no audio).
            inline float wpe_audio_response16(
                thread const float (&left)[16],
                thread const float (&right)[16],
                int mode, float freqMin, float freqMax,
                float2 bounds, float power, float multiply
            ) {
                int lo = clamp(int(freqMin), 0, 15);
                int hi = clamp(int(freqMax), 0, 15);
                float response = 0.0;
                for (int a = lo; a <= hi; ++a) {
                    if (mode == 2) { response += right[a]; }
                    else if (mode == 3) { response += left[a] + right[a]; }
                    else { response += left[a]; }
                }
                float denom = max(freqMax - freqMin + 1.0, 1.0);
                if (mode == 3) { denom *= 2.0; }
                response /= denom;
                response = wpe_smoothstep(bounds.x, bounds.y, response);
                return clamp(pow(response, power), 0.0, 1.0) * multiply;
            }
            inline float wpe_audio_oscilloscope_value(
                float left, float right, int index, int resolution,
                int equalize, float lrBalance, float freqBalanceUniform, float ampExponent
            ) {
                float leftBalance = equalize != 0 ? (1.0 - lrBalance) * 0.5 : 0.5;
                float rightBalance = equalize != 0 ? (lrBalance + 1.0) * 0.5 : 0.5;
                float normalizedFrequency = float(index) / max(float(resolution), 1.0);
                float freqBalance = 1.0;
                if (equalize != 0) {
                    float bassBalance = (1.0 - freqBalanceUniform) * (1.0 - normalizedFrequency);
                    float trebleBalance = freqBalanceUniform * normalizedFrequency;
                    freqBalance = mix(bassBalance, trebleBalance, normalizedFrequency) * 2.5;
                }
                float amplitude = left * leftBalance + right * rightBalance;
                return pow(max(freqBalance * (amplitude + amplitude), 0.0), ampExponent + 0.01);
            }
            inline float4 wpe_waterflow_cycles(float time, float speed) {
                float t = time * speed;
                float4 cycles = float4(fract(t), fract(t + 0.5), fract(0.25 + t), fract(0.25 + t + 0.5));
                return cycles - float4(0.5);
            }
            inline float2 wpe_waterflow_blend(float time, float speed, float feather) {
                float t = time * speed;
                float bx = 2.0 * abs(fract(t) - 0.5);
                float bz = 2.0 * abs(fract(0.25 + t) - 0.5);
                float lo = 0.5 - feather, hi = 0.5 + feather;
                return float2(wpe_smoothstep(lo, hi, bx), wpe_smoothstep(lo, hi, bz));
            }
            inline float3x3 wpe_square_to_quad(float2 p0, float2 p1, float2 p2, float2 p3) {
                float dx0 = p0.x, dy0 = p0.y;
                float dx1 = p1.x, dy1 = p1.y;
                float dx2 = p3.x, dy2 = p3.y;
                float dx3 = p2.x, dy3 = p2.y;
                float diffx1 = dx1 - dx3;
                float diffy1 = dy1 - dy3;
                float diffx2 = dx2 - dx3;
                float diffy2 = dy2 - dy3;
                float det = diffx1 * diffy2 - diffx2 * diffy1;
                float sumx = dx0 - dx1 + dx3 - dx2;
                float sumy = dy0 - dy1 + dy3 - dy2;
                if (det == 0.0 || (sumx == 0.0 && sumy == 0.0)) {
                    return float3x3(
                        float3(dx1 - dx0, dy1 - dy0, 0.0),
                        float3(dx3 - dx1, dy3 - dy1, 0.0),
                        float3(dx0, dy0, 1.0)
                    );
                }
                float ovdet = 1.0 / det;
                float g = (sumx * diffy2 - diffx2 * sumy) * ovdet;
                float h = (diffx1 * sumy - sumx * diffy1) * ovdet;
                return float3x3(
                    float3(dx1 - dx0 + g * dx1, dy1 - dy0 + g * dy1, g),
                    float3(dx2 - dx0 + h * dx2, dy2 - dy0 + h * dy2, h),
                    float3(dx0, dy0, 1.0)
                );
            }
            inline float3x3 wpe_mat3_inverse(float3x3 m) {
                float a00 = m[0][0], a01 = m[0][1], a02 = m[0][2];
                float a10 = m[1][0], a11 = m[1][1], a12 = m[1][2];
                float a20 = m[2][0], a21 = m[2][1], a22 = m[2][2];
                float b01 = a22 * a11 - a12 * a21;
                float b11 = -a22 * a10 + a12 * a20;
                float b21 = a21 * a10 - a11 * a20;
                float det = a00 * b01 + a01 * b11 + a02 * b21;
                float invdet = abs(det) > 0.000001 ? 1.0 / det : 0.0;
                return float3x3(
                    float3(b01, -a22 * a01 + a02 * a21, a12 * a01 - a02 * a11) * invdet,
                    float3(b11, a22 * a00 - a02 * a20, -a12 * a00 + a02 * a10) * invdet,
                    float3(b21, -a21 * a00 + a01 * a20, a11 * a00 - a01 * a10) * invdet
                );
            }
            inline float3 wpe_perspective_texcoord(float2 uv, float2 p0, float2 p1, float2 p2, float2 p3) {
                // WPE: mul(vec3(uv,1), inverse(squareToQuad(...))); WPE mul(x,y) == y * x.
                return wpe_mat3_inverse(wpe_square_to_quad(p0, p1, p2, p3)) * float3(uv, 1.0);
            }
            """
        )
    }

    private static func varyingInitializer(
        for varying: WPEVaryingDecl,
        shaderName: String,
        availableUniforms: Set<String>,
        comboValues: [String: Int] = [:]
    ) -> String {
        // multistage_wave: v_DirectionN = normalize(g_SpinCenter(N+1) - g_SpinCenterN),
        // declared vec4 (.zw = the direction rotated by g_DirectionOffset) under
        // GLOBAL_ROTATION, else vec2. Gated on the per-node g_SpinCenter uniforms so it
        // never intercepts the dualwaves `v_Direction2` case below (which has none).
        if ["float2", "float4"].contains(varying.metalType),
           varying.name.hasPrefix("v_Direction"),
           let nodeIndex = Int(varying.name.dropFirst("v_Direction".count)),
           nodeIndex >= 1, nodeIndex <= 10,
           hasUniforms("g_SpinCenter\(nodeIndex)", "g_SpinCenter\(nodeIndex + 1)", in: availableUniforms) {
            let raw = "wpe_safe_normalize(g_SpinCenter\(nodeIndex + 1) - g_SpinCenter\(nodeIndex))"
            if varying.metalType == "float4" {
                // .zw carries the g_DirectionOffset-rotated direction only under GLOBAL_ROTATION.
                let rotated = comboValues["GLOBAL_ROTATION"] == 1 && availableUniforms.contains("g_DirectionOffset")
                    ? "wpe_rotate_vec2(\(raw), g_DirectionOffset)"
                    : raw
                return "float4(\(raw), \(rotated))"
            }
            return raw
        }
        switch varying.name {
        case "v_TexCoord":
            if varying.metalType == "float2" {
                return "in.uv"
            }
            if varying.metalType == "float4",
               let resolutionUniform = texCoordResolutionUniform(
                shaderName: shaderName,
                availableUniforms: availableUniforms,
                comboValues: comboValues
               ) {
                return "wpe_texcoord_with_resolution(in.uv, \(resolutionUniform))"
            }
        case "v_TexCoordMask":
            if varying.metalType == "float4",
               availableUniforms.contains("g_Texture3Resolution") {
                return "wpe_texcoord_mask(in.uv, g_Texture3Resolution)"
            }
        case "v_Scroll":
            if varying.metalType == "float2",
               hasUniforms("g_ScrollX", "g_ScrollY", "g_Time", in: availableUniforms) {
                return "wpe_scroll_vector(g_ScrollX, g_ScrollY, g_Time)"
            }
        case "v_Direction":
            if varying.metalType == "float2",
               availableUniforms.contains("g_Direction") {
                return "wpe_rotate_vec2(float2(0.0, 1.0), g_Direction)"
            }
        case "v_Direction2":
            // DUALWAVES second wave direction: rotateVec2((0,1), g_Direction2).
            if varying.metalType == "float2",
               availableUniforms.contains("g_Direction2") {
                return "wpe_rotate_vec2(float2(0.0, 1.0), g_Direction2)"
            }
        case "v_TexCoordPerspective", "v_TexCoordFx":
            // PERSPECTIVE / lightshafts: mul(vec3(uv,1), inverse(squareToQuad(g_Point0..3))),
            // matching WPE common_perspective.h byte-for-byte. lightshafts.vert
            // computes `v_TexCoordFx` identically and the fragment does its own
            // `.xy/.z` perspective divide, so the raw homogeneous float3 is correct.
            if varying.metalType == "float3",
               hasUniforms("g_Point0", "g_Point1", "g_Point2", "g_Point3", in: availableUniforms) {
                return "wpe_perspective_texcoord(in.uv, g_Point0, g_Point1, g_Point2, g_Point3)"
            }
            if varying.metalType == "float3" {
                return "float3(in.uv, 1.0)"
            }
        case "v_PerspCoord":
            // audio_responsive_oscilloscope.vert only applies squareToQuad under
            // PERSPECTIVE=1; default PERSPECTIVE=0 is the raw texture coordinate
            // with homogeneous z=1. Using the perspective path unconditionally can
            // make the linear waveform clamp out and leave an opaque solid layer.
            if varying.metalType == "float3" {
                if comboValues["PERSPECTIVE"] == 1,
                   hasUniforms("g_Point0", "g_Point1", "g_Point2", "g_Point3", in: availableUniforms) {
                    return "wpe_perspective_texcoord(in.uv, g_Point0, g_Point1, g_Point2, g_Point3)"
                }
                return "float3(in.uv, 1.0)"
            }
        case "v_ViewCoord":
            // Effects that sample the current full-frame buffer often use
            // `v_ViewCoord.xy / v_ViewCoord.z * 0.5 + 0.5`. Preserve a valid
            // homogeneous z and map back to the current quad UV as a conservative
            // fragment-side reconstruction.
            if varying.metalType == "float3" {
                return "float3(in.uv * 2.0 - 1.0, 1.0)"
            }
        case "audioValue":
            if varying.metalType == "float4" {
                return "float4(0.0)"
            }
        case "v_TexCoordRipple":
            if varying.metalType == "float4",
               hasUniforms(
                "g_Time",
                "g_AnimationSpeed",
                "g_ScrollSpeed",
                "g_Direction",
                "g_Ratio",
                "g_Scale",
                "g_Texture0Resolution",
                in: availableUniforms
               ) {
                return "wpe_ripple_texcoord(in.uv, g_Time, g_AnimationSpeed, g_ScrollSpeed, g_Direction, g_Ratio, g_Scale, g_Texture0Resolution)"
            }
        case "v_TexCoordIris":
            if varying.metalType == "float2",
               hasUniforms(
                "g_Time",
                "g_Speed",
                "g_PhaseOffset",
                "g_Rough",
                "g_NoiseAmount",
                "g_Scale",
                in: availableUniforms
               ) {
                return "wpe_iris_texcoord(g_Time, g_Speed, g_PhaseOffset, g_Rough, g_NoiseAmount, g_Scale)"
            }
        case "v_TexCoordNoise":
            // foliage variant: tiled noise rotated by g_Direction (needs g_Ratio too).
            if varying.metalType == "float4",
               hasUniforms(
                "g_NoiseScale",
                "g_Ratio",
                "g_Direction",
                "g_Texture0Resolution",
                in: availableUniforms
               ) {
                return "wpe_foliage_texcoord_noise(in.uv, g_NoiseScale, g_Ratio, g_Direction, g_Texture0Resolution)"
            }
            // filmgrain variant: two frac(time)-scrolled, g_NoiseScale-tiled lookups.
            // No g_Ratio/g_Direction, so it can't reuse the foliage helper; without this
            // it fell through to raw uv and stretched the noise once across the frame.
            if varying.metalType == "float4",
               hasUniforms("g_NoiseScale", "g_Time", "g_Texture0Resolution", in: availableUniforms) {
                return "wpe_filmgrain_texcoord_noise(in.uv, g_Time, g_NoiseScale, g_Texture0Resolution)"
            }
        case "v_Params":
            if varying.metalType == "float3",
               hasUniforms("g_Direction", "g_Strength", in: availableUniforms) {
                return "wpe_foliage_params(in.uv, g_Direction, g_Strength)"
            }
        case "v_equalScaleFactor":
            // multistage_wave.vert: aspect-correction factor (≥1 per axis), NOT screen UV.
            // Defaulting to in.uv stretched the wave field horizontally across the frame.
            if varying.metalType == "float2",
               availableUniforms.contains("g_Texture0Resolution") {
                return "float2(max(1.0, wpe_safe_ratio(g_Texture0Resolution.x, g_Texture0Resolution.y)), max(1.0, wpe_safe_ratio(g_Texture0Resolution.y, g_Texture0Resolution.x)))"
            }
        case "v_Pulse":
            // pulse.vert: AUDIOPROCESSING → CreateAudioResponse (0 when silent); else a
            // time-driven sine pulse. The float varying used to default to in.uv.x — a
            // left-to-right ramp instead of a uniform full-screen pulse.
            if varying.metalType == "float" {
                let mode = comboValues["AUDIOPROCESSING"] ?? 0
                if mode != 0,
                   hasUniforms(
                    "g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
                    "g_AudioFrequencyMin", "g_AudioFrequencyMax",
                    "g_AudioBounds", "g_AudioPower", "g_AudioMultiply",
                    in: availableUniforms
                   ) {
                    return "wpe_audio_response16(g_AudioSpectrum16Left, g_AudioSpectrum16Right, \(mode), g_AudioFrequencyMin, g_AudioFrequencyMax, g_AudioBounds, g_AudioPower, g_AudioMultiply)"
                }
                if hasUniforms("g_Time", "g_PulseThresholds", "g_PulseSpeed", "g_PulsePhase", "g_PulseAmount", in: availableUniforms) {
                    return "wpe_pulse_response(g_Time, g_PulseThresholds, g_PulseSpeed, g_PulsePhase, g_PulseAmount)"
                }
                return "0.0"
            }
        case "v_ParallaxOffset":
            // depthparallax.vert: pointer-projected offset, ·0.5+0.5. The full form needs
            // g_EffectTextureProjectionMatrixInverse (a mat uniform excluded from fragment
            // injection), so use the vert's own simplified equivalent (= g_ParallaxPosition):
            // neutral (0.5) when the pointer is centered, instead of the in.uv ramp that
            // warped the parallax sample across the screen.
            if varying.metalType == "float2" {
                return availableUniforms.contains("g_ParallaxPosition") ? "g_ParallaxPosition" : "float2(0.5)"
            }
        case "v_Bounds":
            if varying.metalType == "float2",
               availableUniforms.contains("g_Bounds") {
                return "wpe_bounds_vector(g_Bounds)"
            }
        case "v_Cycles":
            // waterflow.vert: four scroll-loop phases (frac(t·speed)+offsets) − 0.5,
            // bounded to ±0.5 so the flow displacement oscillates instead of growing
            // with screen position (the default float4(uv,uv) caused the smear band).
            if varying.metalType == "float4",
               hasUniforms("g_Time", "g_FlowSpeed", in: availableUniforms) {
                return "wpe_waterflow_cycles(g_Time, g_FlowSpeed)"
            }
        case "v_Blend":
            // waterflow.vert: smoothstep cross-fade weights between the two phase samples.
            if varying.metalType == "float2",
               hasUniforms("g_Time", "g_FlowSpeed", "g_PhaseFeather", in: availableUniforms) {
                return "wpe_waterflow_blend(g_Time, g_FlowSpeed, g_PhaseFeather)"
            }
        case "v_AudioShift":
            // Audio-reactive scalar computed in the vertex stage (CreateAudioResponse).
            // Reconstruct it from the spectrum + audio uniforms so it rests at 0 when
            // silent instead of falling through to the `in.uv.x` float default, which
            // smeared chromatic_aberration / hue_shift across the whole frame.
            if varying.metalType == "float",
               hasUniforms(
                "g_AudioSpectrum16Left",
                "g_AudioSpectrum16Right",
                "g_AudioFrequencyMin",
                "g_AudioFrequencyMax",
                "g_AudioBounds",
                "g_AudioPower",
                "g_AudioMultiply",
                in: availableUniforms
               ) {
                let mode = comboValues["AUDIOPROCESSING"] ?? 1
                return "wpe_audio_response16(g_AudioSpectrum16Left, g_AudioSpectrum16Right, \(mode), g_AudioFrequencyMin, g_AudioFrequencyMax, g_AudioBounds, g_AudioPower, g_AudioMultiply)"
            }
            return "0.0"
        case "v_AudioPulse":
            // Audio-reactive pulse (CreateAudioResponse): 0 when silent, like v_AudioShift.
            // Reconstruct the real response when the spectrum uniforms are present so the
            // effect reacts to audio instead of staying flat; falls back to 0 otherwise.
            if varying.metalType == "float" {
                let mode = comboValues["AUDIOPROCESSING"] ?? 1
                if hasUniforms(
                    "g_AudioSpectrum16Left", "g_AudioSpectrum16Right",
                    "g_AudioFrequencyMin", "g_AudioFrequencyMax",
                    "g_AudioBounds", "g_AudioPower", "g_AudioMultiply",
                    in: availableUniforms
                ) {
                    return "wpe_audio_response16(g_AudioSpectrum16Left, g_AudioSpectrum16Right, \(mode), g_AudioFrequencyMin, g_AudioFrequencyMax, g_AudioBounds, g_AudioPower, g_AudioMultiply)"
                }
                return "0.0"
            }
        default:
            break
        }

        switch varying.metalType {
        case "float2":
            return "in.uv"
        case "float3":
            return "float3(in.uv, 0.0)"
        case "float4":
            return "float4(in.uv, in.uv)"
        case "float":
            return "in.uv.x"
        default:
            return "\(varying.metalType)(0)"
        }
    }

    private static func symbolicArrayReconstructionLines(
        for varying: WPEVaryingDecl,
        availableUniforms: Set<String>,
        comboValues: [String: Int]
    ) -> [String] {
        guard varying.name == "audioValue",
              varying.metalType == "float4" else {
            return []
        }

        let resolution = comboValues["RESOLUTION"] ?? 32
        let leftName: String
        let rightName: String
        switch resolution {
        case 16:
            leftName = "g_AudioSpectrum16Left"
            rightName = "g_AudioSpectrum16Right"
        case 64:
            leftName = "g_AudioSpectrum64Left"
            rightName = "g_AudioSpectrum64Right"
        default:
            leftName = "g_AudioSpectrum32Left"
            rightName = "g_AudioSpectrum32Right"
        }

        guard hasUniforms(leftName, rightName, "u_ampExponent", "u_FreqBalance", "u_LRBalance", in: availableUniforms) else {
            return []
        }

        let equalize = comboValues["EQUALIZE"] ?? 0
        return [
            "    for (int wpeAudioIndex = 0; wpeAudioIndex < \(resolution); wpeAudioIndex += 4) {",
            "        \(varying.name)[wpeAudioIndex / 4] = float4(",
            "            wpe_audio_oscilloscope_value(\(leftName)[wpeAudioIndex + 0], \(rightName)[wpeAudioIndex + 0], wpeAudioIndex + 0, \(resolution), \(equalize), u_LRBalance, u_FreqBalance, u_ampExponent),",
            "            wpe_audio_oscilloscope_value(\(leftName)[wpeAudioIndex + 1], \(rightName)[wpeAudioIndex + 1], wpeAudioIndex + 1, \(resolution), \(equalize), u_LRBalance, u_FreqBalance, u_ampExponent),",
            "            wpe_audio_oscilloscope_value(\(leftName)[wpeAudioIndex + 2], \(rightName)[wpeAudioIndex + 2], wpeAudioIndex + 2, \(resolution), \(equalize), u_LRBalance, u_FreqBalance, u_ampExponent),",
            "            wpe_audio_oscilloscope_value(\(leftName)[wpeAudioIndex + 3], \(rightName)[wpeAudioIndex + 3], wpeAudioIndex + 3, \(resolution), \(equalize), u_LRBalance, u_FreqBalance, u_ampExponent)",
            "        );",
            "    }"
        ]
    }

    private static func hasUniforms(_ names: String..., in availableUniforms: Set<String>) -> Bool {
        names.allSatisfy { availableUniforms.contains($0) }
    }

    private static func texCoordResolutionUniform(
        shaderName: String,
        availableUniforms: Set<String>,
        comboValues: [String: Int] = [:]
    ) -> String? {
        let lowercased = shaderName.lowercased()
        // WPE distortion shaders (waterwaves/waterripple/foliagesway…) scale
        // `v_TexCoord.zw` by the *active auxiliary texture's* resolution,
        // mirroring the `#if MASK / #elif TIMEOFFSET` ladder in the .vert:
        // MASK uses the opacity-mask texture (g_Texture1), TIMEOFFSET uses the
        // time-offset texture (g_Texture2). The previous combo-blind heuristic
        // always picked g_Texture1Resolution, mis-scaling the TIMEOFFSET case.
        if comboValues["MASK"] == 1, availableUniforms.contains("g_Texture1Resolution") {
            return "g_Texture1Resolution"
        }
        if comboValues["TIMEOFFSET"] == 1, availableUniforms.contains("g_Texture2Resolution") {
            return "g_Texture2Resolution"
        }
        if lowercased.contains("pulse"), availableUniforms.contains("g_Texture2Resolution") {
            return "g_Texture2Resolution"
        }
        if availableUniforms.contains("g_Texture1Resolution") {
            return "g_Texture1Resolution"
        }
        if availableUniforms.contains("g_Texture2Resolution") {
            return "g_Texture2Resolution"
        }
        return nil
    }

    /// Map `g_Texture0` / `g_Texture1` etc. to a slot index by parsing the trailing digit.
    private static func textureSlot(for name: String) -> Int? {
        let prefix = "g_Texture"
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}

// MARK: - Result types

struct WPEShaderTranslationResult {
    let mslSource: String
    let samplers: [String]
    let uniformLayout: [WPEUniformSlot]
    /// Total float4 slots needed for this shader's uniforms — capped by
    /// `WPEShaderTranspiler.uniformSlotMaximum`.
    let totalSlots: Int
}

struct WPEUniformSlot: Equatable {
    let name: String
    let glslType: String
    let slot: Int           // first float4 index occupied
    let slotCount: Int      // total number of slots used
    let arrayLength: Int?   // present when the source declared an array
    let materialName: String?
    let defaultValue: WPESceneShaderConstantValue?

    init(
        name: String,
        glslType: String,
        slot: Int,
        slotCount: Int,
        arrayLength: Int? = nil,
        materialName: String? = nil,
        defaultValue: WPESceneShaderConstantValue? = nil
    ) {
        self.name = name
        self.glslType = glslType
        self.slot = slot
        self.slotCount = slotCount
        self.arrayLength = arrayLength
        self.materialName = materialName
        self.defaultValue = defaultValue
    }
}

struct WPESamplerDecl: Equatable {
    let name: String
    let comment: String?

    static func parse(line: String) -> Self? {
        guard line.hasPrefix("uniform ") else { return nil }
        let body = line.dropFirst("uniform ".count)
        guard body.hasPrefix("sampler2D ") else { return nil }
        let rest = body.dropFirst("sampler2D ".count)
        let parts = rest.split(separator: ";", maxSplits: 1)
        guard let head = parts.first else { return nil }
        let name = head.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let comment = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        return Self(name: name, comment: comment)
    }
}

struct WPEUniformDecl: Equatable {
    let type: String         // GLSL type name as written in source
    let name: String         // Identifier without any `[N]` suffix
    let metalType: String    // Translated for use in the Metal struct
    /// When the declaration is `float foo[16];` this is `16`; otherwise nil.
    let arrayLength: Int?
    /// WPE shaders commonly expose editor values as JSON comments after
    /// uniforms, e.g. `uniform float u_alpha; // {"material":"Opacity"}`.
    /// Scene effect overrides use that material name, not the GLSL variable.
    let materialName: String?
    let defaultValue: WPESceneShaderConstantValue?

    static func parse(line: String) -> Self? {
        guard line.hasPrefix("uniform ") else { return nil }
        let body = String(line.dropFirst("uniform ".count))
        if body.hasPrefix("sampler") { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let semicolon = trimmed.firstIndex(of: ";") else { return nil }
        let decl = trimmed[..<semicolon]
        let comment = trimmed[trimmed.index(after: semicolon)...]
        let tokens = decl.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let type = tokens[0]
        let nameToken = tokens[1...].joined()
        var name = nameToken
        var arrayLength: Int?
        if let bracket = name.firstIndex(of: "[") {
            let core = String(name[..<bracket])
            let after = name[name.index(after: bracket)...]
            if let close = after.firstIndex(of: "]") {
                let lengthString = String(after[..<close]).trimmingCharacters(in: .whitespaces)
                arrayLength = Int(lengthString)
            }
            name = core
        }
        guard !name.isEmpty else { return nil }
        let metal = mapType(type)
        let metadata = Self.parseMetadataComment(String(comment))
        return Self(
            type: type,
            name: name,
            metalType: metal,
            arrayLength: arrayLength,
            materialName: metadata.materialName,
            defaultValue: metadata.defaultValue
        )
    }

    private static func parseMetadataComment(_ raw: String) -> (
        materialName: String?,
        defaultValue: WPESceneShaderConstantValue?
    ) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return (nil, nil)
        }
        let jsonText = String(trimmed[start...end])
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(jsonText.utf8),
            options: [.allowFragments]
        ) as? [String: Any] else {
            return (nil, nil)
        }
        return (
            json["material"] as? String,
            json["default"].flatMap { WPEValueParser.shaderConstant($0) }
        )
    }

    static func mapType(_ glsl: String) -> String {
        switch glsl {
        case "vec2": return "float2"
        case "vec3": return "float3"
        case "vec4": return "float4"
        case "mat2": return "float2x2"
        case "mat3": return "float3x3"
        case "mat4": return "float4x4"
        case "ivec2": return "int2"
        case "ivec3": return "int3"
        case "ivec4": return "int4"
        case "bvec2": return "bool2"
        case "bvec3": return "bool3"
        case "bvec4": return "bool4"
        case "bool": return "bool"
        case "int": return "int"
        case "float": return "float"
        default: return glsl
        }
    }
}

struct WPEVaryingDecl: Equatable {
    let type: String
    let name: String
    let metalType: String
    let arrayLength: Int?
    /// Raw bracket dimension when the source declared an array (`[64]` or a `#define`d symbol like
    /// `[RESOLUTION]`). `arrayLength` is the numeric value when it parses; for a symbolic dim it's nil
    /// but `arrayDimension` keeps the token, which resolves to a constant in the emitted MSL.
    let arrayDimension: String?

    static func parse(line: String) -> Self? {
        let prefix: String
        if line.hasPrefix("varying ") {
            prefix = "varying "
        } else if line.hasPrefix("in ") {
            prefix = "in "
        } else {
            return nil
        }
        let body = String(line.dropFirst(prefix.count))
        guard let semicolon = body.firstIndex(of: ";") else { return nil }
        let decl = body[..<semicolon]
        let tokens = decl.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let rawName = tokens[1]
        // The dimension may be a numeric literal (`[64]`) or a `#define`d symbol (`[RESOLUTION]`),
        // so match any non-`]` token, not just digits. A symbolic dim leaking into `name` was the
        // `audioValue[RESOLUTION]` → invalid-MSL bug (oscilloscope shaders).
        let pattern = #"^([A-Za-z_][A-Za-z0-9_]*)(?:\[([^\]]+)\])?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawName, range: NSRange(rawName.startIndex..., in: rawName)),
              let nameRange = Range(match.range(at: 1), in: rawName) else {
            return Self(type: tokens[0], name: rawName, metalType: WPEUniformDecl.mapType(tokens[0]), arrayLength: nil, arrayDimension: nil)
        }

        let arrayDimension: String?
        let arrayLength: Int?
        if match.range(at: 2).location != NSNotFound,
           let dimRange = Range(match.range(at: 2), in: rawName) {
            let token = rawName[dimRange].trimmingCharacters(in: .whitespaces)
            arrayDimension = token
            arrayLength = Int(token)
        } else {
            arrayDimension = nil
            arrayLength = nil
        }

        return Self(
            type: tokens[0],
            name: String(rawName[nameRange]),
            metalType: WPEUniformDecl.mapType(tokens[0]),
            arrayLength: arrayLength,
            arrayDimension: arrayDimension
        )
    }
}
#endif
