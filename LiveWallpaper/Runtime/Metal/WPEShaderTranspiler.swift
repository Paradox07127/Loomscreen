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
            let parsedUniforms = WPEUniformDecl.parseAll(line: trimmed)
            if !parsedUniforms.isEmpty {
                uniforms.append(contentsOf: parsedUniforms)
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

        // Sampler wrap (clamp vs repeat) and filter are NOT decided here anymore: every
        // `g_TextureN.sample` is rewritten to the per-slot runtime sampler `wpeSamplerN`
        // (`rewriteSamplersToPerSlot`), whose address/filter the executor binds from the
        // texture's TEXI flags. The old "annotate a sampler as noise → repeatSampler"
        // heuristic is retired — it couldn't see per-texture ClampUVs and missed
        // water-normal / flow maps (waterripple froze).
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
        let preserveTexCoordZW = shouldPreserveTexCoordZW(shaderName: shaderName, comboValues: comboValues)
        let translatedHelpers = applySubstitutions(
            preMain + "\n" + postMain,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots
        )
        let translatedMain = translateMain(
            mainBody,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots,
            premultiplyOutput: premultipliedOutput
        )
        // Convert `g_TextureN.sample(linear|repeatSampler, …)` → the per-slot runtime
        // sampler `wpeSamplerN` in BOTH helper and main bodies BEFORE resource threading,
        // so `rewriteHelperResourceAccess` sees `wpeSamplerN` in a helper body and wires
        // it into that helper's signature/call (via its `samplerStateResources`). Runs
        // after the `linearSampler`-keyed narrowing / LOD rewrites (inside the translate
        // calls above), so those still matched the literal name.
        let perSlotHelpers = Self.rewriteSamplersToPerSlot(translatedHelpers)
        let perSlotMain = Self.rewriteSamplersToPerSlot(translatedMain)
        let helperMutableGlobals = extractProgramScopeMutableDeclarations(from: perSlotHelpers)
        let helperResources = rewriteHelperResourceAccess(
            helpers: helperMutableGlobals.source,
            mainBody: perSlotMain,
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

    static func slotCount(for glslType: String) -> Int {
        switch glslType {
        case "mat2": return 2
        case "mat3": return 3
        case "mat4": return 4
        default:    return 1
        }
    }

}
#endif
