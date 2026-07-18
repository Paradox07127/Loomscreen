#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

// Reconstruction of vertex-stage varyings for the fragment-only transpile path:
// the auto_sway (foliage) chain and the `v_TexCoord.zw` resolution-scaled aux UV
// families. Split out of +Render/+Substitutions so the hotspot files don't grow.
extension WPEShaderTranspiler {
    // MARK: - auto_sway varying reconstruction

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
    static func autoSwayVaryingReconstructionLines(
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

    // MARK: - v_TexCoord.zw resolution-scaled aux UV families

    /// Engine effect `.vert`s compute a resolution-scaled aux UV into `v_TexCoord.zw`
    /// (`uv·res.zw/res.xy` — the POT-padding/aspect correction for the mask, flow, or
    /// blend texture), which the fragment-only path synthesizes byte-for-byte via
    /// `wpe_texcoord_with_resolution(in.uv, g_TextureNResolution)`. For the families in
    /// `texCoordZWResolutionSlot` we keep the `.zw` sample so that correction survives.
    /// For every other shader the synthesized `.zw` is NOT guaranteed to match the source
    /// `.vert` (blur-step verts, swing/twirl's aspect+sine packing, TRANSFORMUV blends),
    /// so we keep the historical `.xy` fallback.
    static func rewriteTexCoordMaskUVFallback(
        _ source: String,
        varyingTypesByName: [String: String],
        preserveTexCoordZW: Bool
    ) -> String {
        guard preserveTexCoordZW, varyingTypesByName["v_TexCoord"] == "float4" else {
            return source.replacingOccurrences(of: "v_TexCoord.zw", with: "v_TexCoord.xy")
        }
        return source
    }

    static func shouldPreserveTexCoordZW(shaderName: String, comboValues: [String: Int]) -> Bool {
        // swing/twirl: .zw = aspect + sine phase, rebuilt by their varyingInitializer
        // case. Safe even when its uniform gate fails: the float4 default leaves
        // .zw == uv — exactly what the historical .xy downgrade produced.
        if let family = texCoordZWFamilyName(shaderName: shaderName),
           family == "swing" || family == "twirl" {
            return true
        }
        return texCoordZWResolutionSlot(shaderName: shaderName, comboValues: comboValues) != nil
    }

    /// Effect families whose source `.vert` writes `v_TexCoord.zw = uv * resN.zw / resN.xy`
    /// (verified line-by-line against the engine's `assets/effects/*/shaders` `.vert`s).
    /// Returns the texture slot N whose resolution the `.vert` reads, or nil when the
    /// family's `.zw` carries different semantics and must keep the `.xy` downgrade.
    /// Excluded on purpose: blur_precise_gaussian/shine_gaussian/godrays_gaussian
    /// (directional blur step), shine_combine/godrays_combine (HLSL-only half-texel
    /// shift; GL `.zw` == uv), swing/twirl (aspect + sine time packing — rebuilt by
    /// their dedicated `varyingInitializer` case instead), spin (never
    /// writes `.zw`, so `.xy` is exact), fluidsimulation_clear (pressure decay).
    static func texCoordZWResolutionSlot(shaderName: String, comboValues: [String: Int]) -> Int? {
        guard let family = texCoordZWFamilyName(shaderName: shaderName) else { return nil }
        switch family {
        case "waterwaves":
            // waterwaves.vert ladder: MASK scales by T1, else TIMEOFFSET by T2.
            // Both off leaves .zw unscaled AND unread, so the slot-1 default is inert.
            return comboValues["TIMEOFFSET"] == 1 && comboValues["MASK"] != 1 ? 2 : 1
        case "blend", "blendgradient":
            // TRANSFORMUV == 1 appends offset/rotate/scale steps after the resolution
            // scale that we don't synthesize — keep the historical .xy downgrade there.
            return comboValues["TRANSFORMUV"] == 1 ? nil : 1
        case "foliagesway":
            // MODE != 0 (vertex-displacement sway) leaves .zw = (0,0) — a constant
            // mask sample we can't reproduce with a scaled UV; keep the downgrade.
            return (comboValues["MODE"] ?? 0) == 0 ? 1 : nil
        // glitter_combine binds its mask at slot 2 but its .vert scales by
        // g_Texture1Resolution (upstream WPE quirk; slot 1 is the built-in 256²
        // glitter noise, ratio 1) — replicate verbatim, don't "fix" to slot 2.
        case "glitter_combine", "waterflow", "tint", "shake", "iris",
             "localcontrast_combine", "cloudmotion", "chromatic_aberration", "fire",
             "caustics", "opacity", "blur_combine", "godrays_downsample2",
             "depthparallax", "reflection", "xray", "shimmer", "shine_downsample2":
            return 1
        case "refract", "motionblur_accumulation", "vhs", "pulse", "clouds",
             "filmgrain", "nitro", "waterripple":
            return 2
        case "lightshafts":
            return 3
        default:
            return nil
        }
    }

    /// Family key = the shader basename when the path sits in an `effects/` directory
    /// (`effects/reflection`, `workshop/…/effects/reflection`) or uses the flat
    /// `effect_reflection` form — the same shapes the old allowlist accepted. Paths
    /// outside `effects/` return nil so arbitrary workshop shaders that happen to share
    /// a basename don't inherit engine `.vert` semantics.
    static func texCoordZWFamilyName(shaderName: String) -> String? {
        let normalized = shaderName
            .lowercased()
            .replacingOccurrences(of: ".frag", with: "")
            .replacingOccurrences(of: ".vert", with: "")
        if normalized.hasPrefix("effect_") {
            return String(normalized.dropFirst("effect_".count))
        }
        guard let range = normalized.range(of: "effects/", options: .backwards) else { return nil }
        if range.lowerBound != normalized.startIndex,
           normalized[normalized.index(before: range.lowerBound)] != "/" {
            return nil
        }
        let family = String(normalized[range.upperBound...])
        guard !family.isEmpty, !family.contains("/") else { return nil }
        return family
    }
}
#endif
