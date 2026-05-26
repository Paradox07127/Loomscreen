#if !LITE_BUILD
import Foundation

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
        let lines = scrubbedSource.components(separatedBy: "\n")

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
        _ = !varyings.isEmpty || preprocessedSource.contains("v_TexCoord") || preprocessedSource.contains("gl_FragCoord")

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

        let msl = renderMSL(
            shaderName: shaderName,
            uniforms: uniforms,
            samplers: sortedSamplers,
            varyings: varyings,
            helpers: translatedHelpers,
            mainBody: translatedMain
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
                arrayLength: u.arrayLength
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
        inner = applySubstitutions(inner)

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
    private static func applySubstitutions(_ source: String) -> String {
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

        s = rewriteTextureCalls(s)

        s = rewriteReferenceParameters(s)

        s = stripInParameterQualifier(s)

        return s
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

        out.append("constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);")
        out.append("")

        if !helpers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(helpers)
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

        for (slot, sampler) in samplers.enumerated() {
            out.append("    auto \(sampler.name) = tex\(slot);")
        }
        for varying in varyings {
            if varying.name == "uv" { continue }
            switch varying.metalType {
            case "float2":
                out.append("    float2 \(varying.name) = in.uv;")
            case "float3":
                out.append("    float3 \(varying.name) = float3(in.uv, 0.0);")
            case "float4":
                out.append("    float4 \(varying.name) = float4(in.uv, in.uv);")
            case "float":
                out.append("    float \(varying.name) = in.uv.x;")
            default:
                out.append("    \(varying.metalType) \(varying.name) = \(varying.metalType)(0);")
            }
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
                out.append("    \(elementType) \(u.name)[\(arrayLength)];")
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
                out.append("    float \(u.name) = u.vals[\(slotCursor)].x;")
            case "vec2":
                out.append("    float2 \(u.name) = u.vals[\(slotCursor)].xy;")
            case "vec3":
                out.append("    float3 \(u.name) = u.vals[\(slotCursor)].xyz;")
            case "vec4":
                out.append("    float4 \(u.name) = u.vals[\(slotCursor)];")
            case "int":
                out.append("    int \(u.name) = int(u.vals[\(slotCursor)].x);")
            case "bool":
                out.append("    bool \(u.name) = u.vals[\(slotCursor)].x > 0.5;")
            case "mat2":
                out.append("    float2x2 \(u.name) = float2x2(u.vals[\(slotCursor)].xy, u.vals[\(slotCursor + 1)].xy);")
            case "mat3":
                out.append("    float3x3 \(u.name) = float3x3(u.vals[\(slotCursor)].xyz, u.vals[\(slotCursor + 1)].xyz, u.vals[\(slotCursor + 2)].xyz);")
            case "mat4":
                out.append("    float4x4 \(u.name) = float4x4(u.vals[\(slotCursor)], u.vals[\(slotCursor + 1)], u.vals[\(slotCursor + 2)], u.vals[\(slotCursor + 3)]);")
            default:
                out.append("    \(u.metalType) \(u.name) = u.vals[\(slotCursor)].x;")
            }
            slotCursor += slots
        }

        out.append(mainBody)
        out.append("}")
        return out.joined(separator: "\n")
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

    init(name: String, glslType: String, slot: Int, slotCount: Int, arrayLength: Int? = nil) {
        self.name = name
        self.glslType = glslType
        self.slot = slot
        self.slotCount = slotCount
        self.arrayLength = arrayLength
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

    static func parse(line: String) -> Self? {
        guard line.hasPrefix("uniform ") else { return nil }
        let body = String(line.dropFirst("uniform ".count))
        if body.hasPrefix("sampler") { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let semicolon = trimmed.firstIndex(of: ";") else { return nil }
        let decl = trimmed[..<semicolon]
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
        return Self(type: type, name: name, metalType: metal, arrayLength: arrayLength)
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
        return Self(type: tokens[0], name: tokens[1], metalType: WPEUniformDecl.mapType(tokens[0]))
    }
}
#endif
