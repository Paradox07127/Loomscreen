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
///       texture2d<float> tex1 [[texture(1)]],
///       texture2d<float> tex2 [[texture(2)]],
///       texture2d<float> tex3 [[texture(3)]]
///   ) { ... }
///
/// Out of scope (returns `.translationFailed`):
///   - vertex shaders that aren't the standard fullscreen quad
///   - geometry/tessellation
///   - bit-level integer ops, atomics
///   - `discard` / `gl_FragData[*]` MRT
///   - sampler arrays, texture arrays, cube maps, 3D textures
///
/// Unsupported shaders surface as `metalRendererUnsupported`; automatic
/// sessions fall back to WebGL, user-pinned Metal surfaces the error.
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
    /// Cap sized for workshop audio-bar visualizers like
    /// `Simple_Audio_Bars` (245 slots = stereo 64-bucket spectra + per-bar
    /// state + color palettes). 256 slots × 16 bytes = 4 KB, the inline
    /// upper bound for `setFragmentBytes` on macOS — if a future shader
    /// asks for more, the binding in `WPEMetalShaderDispatcher` needs to
    /// switch to `setFragmentBuffer` first.
    static let uniformSlotMaximum = 256

    /// Translate a preprocessed WPE fragment shader to MSL.
    static func translateFragment(
        shaderName: String,
        preprocessedSource: String
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
        guard sortedSamplers.count <= 4 else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' uses \(sortedSamplers.count) samplers; transpiler supports up to 4"
            )
        }
        // Wallpaper Engine allows sampler slots g_Texture0–g_Texture7, but this
        // pipeline only declares tex0–tex3 and the dispatcher binds slots 0..<4.
        // A sampler at slot ≥ 4 would alias to an undeclared `texN` (MSL compile
        // failure), so reject it explicitly — the engine can't bind it anyway.
        if let maxSlot = sortedSamplers.compactMap({ Self.textureSlot(for: $0.name) }).max(), maxSlot >= 4 {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' binds texture slot \(maxSlot); transpiler supports slots 0–3"
            )
        }
        _ = !varyings.isEmpty || activeSource.contains("v_TexCoord") || activeSource.contains("gl_FragCoord")

        let body = bodyLines.joined(separator: "\n")
        guard let mainRange = Self.locateMain(in: body) else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' has no recognizable `void main()` entry point"
            )
        }
        let preMain = String(body[..<mainRange.lowerBound])
        let mainBody = String(body[mainRange])
        let postMain = String(body[mainRange.upperBound...])

        let translatedHelpers = applySubstitutions(preMain + "\n" + postMain)
        let translatedMain = translateMain(mainBody)
        let helperResources = rewriteHelperResourceAccess(
            helpers: translatedHelpers,
            mainBody: translatedMain,
            uniforms: uniforms,
            samplers: sortedSamplers
        )

        let msl = renderMSL(
            shaderName: shaderName,
            uniforms: uniforms,
            samplers: sortedSamplers,
            varyings: varyings,
            helpers: helperResources.helpers,
            mainBody: helperResources.mainBody
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
        parsePreprocessorExpression(expression, values: values, definedMacros: definedMacros) ?? 0
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
    private static func translateMain(_ source: String) -> String {
        guard let openBrace = source.range(of: "{") else { return "" }
        guard let closeBrace = source.range(of: "}", options: .backwards) else { return "" }
        var inner = String(source[openBrace.upperBound..<closeBrace.lowerBound])
        inner = applySubstitutions(inner, rewriteProgramScopeConsts: false)

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
                + "\nreturn out_color;\n"
        } else {
            inner = inner + "\nreturn float4(0.0);\n"
        }
        return inner
    }

    // MARK: - Type / intrinsic substitutions

    /// Apply token-level substitutions for the GLSL→MSL gap.
    private static func applySubstitutions(_ source: String, rewriteProgramScopeConsts: Bool = true) -> String {
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

        if rewriteProgramScopeConsts {
            s = rewriteProgramScopeConstDeclarations(s)
        }
        s = rewriteReservedIdentifiers(s)
        s = rewriteTextureCalls(s)
        s = rewriteTexCoordTextureSampleUVFallback(s)
        s = rewriteTextureSampleNarrowing(s)
        s = rewriteVector4TextureSampleLocalsInSampleCoordinates(s)
        s = rewriteSwizzledMixAssignments(s)
        s = rewriteUnsignedFloatModuloAssignments(s)
        s = rewriteFloatAssignmentsFromVectorExpressions(s)
        s = rewritePointerPositionFloatAssignments(s)
        s = rewriteTextureResolutionVector2Assignments(s)
        s = rewriteVectorConstructorNarrowing(s)
        s = rewriteTexCoordVector2Arithmetic(s)
        s = rewriteTexCoordMaskUVFallback(s)
        s = rewriteGLSLArrayConstructors(s)

        s = rewriteReferenceParameters(s)

        s = stripInParameterQualifier(s)

        return s
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
        let pattern = #"(\.sample\s*\(\s*linearSampler\s*,\s*)v_TexCoord(\s*\))"#
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
        let declarationPattern = #"\bfloat4\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*[A-Za-z_][A-Za-z0-9_]*\.sample\s*\("#
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
        let pattern = #"\b(float|float2|float3)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*\.sample\([^;\n]+\))\s*;"#
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

    /// WPE workshop shaders often declare v_TexCoord as vec3 while using it as
    /// a vec2 UV in arithmetic with CAST2/vec2 values.
    private static func rewriteTexCoordVector2Arithmetic(_ source: String) -> String {
        let pattern = #"\bv_TexCoord\s*([+\-])\s*((?:float2|CAST2)\s*\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "v_TexCoord.xy $1 $2"
        )
    }

    /// Some WPE effects compute secondary mask UVs into `v_TexCoord.zw` in the
    /// vertex shader, but this fullscreen Metal path only exposes base UVs.
    /// Falling back to `.xy` preserves compilation and the common mask behavior.
    private static func rewriteTexCoordMaskUVFallback(_ source: String) -> String {
        source.replacingOccurrences(of: "v_TexCoord.zw", with: "v_TexCoord.xy")
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

    /// Rewrite `texture(<sampler>, <uv>)` calls (already canonicalised by the preprocessor) into Metal `<sampler>.sample(linearSampler, uv)` form.
    private static func rewriteTextureCalls(_ source: String) -> String {
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
                        result += "\(sampler).sample(linearSampler, \(uv))"
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
        samplers: [WPESamplerDecl]
    ) -> (helpers: String, mainBody: String) {
        let functions = parseHelperFunctions(in: helpers)
        guard !functions.isEmpty else {
            return (helpers, mainBody)
        }

        let resources = helperResources(uniforms: uniforms, samplers: samplers)
        guard !resources.isEmpty else {
            return (helpers, mainBody)
        }
        let macroDependencies = helperMacroDependencies(in: helpers, resources: resources)

        let functionNames = Set(functions.map(\.name))
        var dependenciesByFunction: [String: Set<String>] = [:]
        var callsByFunction: [String: Set<String>] = [:]

        for function in functions {
            let body = String(helpers[function.bodyRange])
            var dependencies = Set(
                resources
                    .filter { containsIdentifier($0.name, in: body) }
                    .map(\.name)
            )
            for (macroName, macroResources) in macroDependencies where containsIdentifier(macroName, in: body) {
                dependencies.formUnion(macroResources)
            }
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
        samplers: [WPESamplerDecl]
    ) -> [HelperResource] {
        let samplerResources = samplers.map {
            HelperResource(name: $0.name, parameterType: "texture2d<float>")
        }
        let uniformResources = uniforms.map {
            HelperResource(name: $0.name, parameterType: helperParameterType(for: $0))
        }
        return samplerResources + uniformResources
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
        mainBody: String
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
            out.append("struct WPEUniforms {")
            out.append("    float4 vals[\(WPEShaderTranspiler.uniformSlotMaximum)];")
            out.append("};")
            out.append("")
        }

        out.append("[[maybe_unused]] constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);")
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
        for slot in 0..<4 {
            let comma = slot < 3 ? "," : ""
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
            case "bool":
                out.append("    [[maybe_unused]] bool \(u.name) = u.vals[\(slotCursor)].x > 0.5;")
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
        for varying in varyings {
            if varying.name == "uv" { continue }
            let initializer = varyingInitializer(
                for: varying,
                shaderName: shaderName,
                availableUniforms: uniformNames
            )
            if let arrayLength = varying.arrayLength {
                let initializers = Array(repeating: initializer, count: arrayLength).joined(separator: ", ")
                out.append("    [[maybe_unused]] \(varying.metalType) \(varying.name)[\(arrayLength)] = { \(initializers) };")
            } else {
                out.append("    [[maybe_unused]] \(varying.metalType) \(varying.name) = \(initializer);")
            }
        }

        out.append("    {")
        out.append(warningCleanMainBody)
        out.append("    }")
        out.append("}")
        return out.joined(separator: "\n")
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
                float eased = smoothstep(1.0 - rough, 1.0, cos(fract(time) * 3.14159265359) * -0.5 + 0.5);
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
            inline float2 wpe_bounds_vector(float2 bounds) {
                return float2(bounds.x, 1.0 / max(bounds.y - bounds.x, 0.000001));
            }
            """
        )
    }

    private static func varyingInitializer(
        for varying: WPEVaryingDecl,
        shaderName: String,
        availableUniforms: Set<String>
    ) -> String {
        switch varying.name {
        case "v_TexCoord":
            if varying.metalType == "float2" {
                return "in.uv"
            }
            if varying.metalType == "float4",
               let resolutionUniform = texCoordResolutionUniform(
                shaderName: shaderName,
                availableUniforms: availableUniforms
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
        case "v_Params":
            if varying.metalType == "float3",
               hasUniforms("g_Direction", "g_Strength", in: availableUniforms) {
                return "wpe_foliage_params(in.uv, g_Direction, g_Strength)"
            }
        case "v_Bounds":
            if varying.metalType == "float2",
               availableUniforms.contains("g_Bounds") {
                return "wpe_bounds_vector(g_Bounds)"
            }
        case "v_AudioPulse":
            if varying.metalType == "float" {
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

    private static func hasUniforms(_ names: String..., in availableUniforms: Set<String>) -> Bool {
        names.allSatisfy { availableUniforms.contains($0) }
    }

    private static func texCoordResolutionUniform(
        shaderName: String,
        availableUniforms: Set<String>
    ) -> String? {
        let lowercased = shaderName.lowercased()
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
        let pattern = #"^([A-Za-z_][A-Za-z0-9_]*)(?:\[(\d+)\])?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawName, range: NSRange(rawName.startIndex..., in: rawName)),
              let nameRange = Range(match.range(at: 1), in: rawName) else {
            return Self(type: tokens[0], name: rawName, metalType: WPEUniformDecl.mapType(tokens[0]), arrayLength: nil)
        }

        let arrayLength: Int?
        if match.range(at: 2).location != NSNotFound,
           let lengthRange = Range(match.range(at: 2), in: rawName) {
            arrayLength = Int(rawName[lengthRange])
        } else {
            arrayLength = nil
        }

        return Self(
            type: tokens[0],
            name: String(rawName[nameRange]),
            metalType: WPEUniformDecl.mapType(tokens[0]),
            arrayLength: arrayLength
        )
    }
}
#endif
