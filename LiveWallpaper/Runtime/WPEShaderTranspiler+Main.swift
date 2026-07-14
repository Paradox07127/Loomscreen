#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

extension WPEShaderTranspiler {
    // MARK: - main() handling

    /// Range covering everything from `void main()` through the matching closing brace.
    static func locateMain(in source: String) -> Range<String.Index>? {
        // Discover on a comment-masked copy so a `/* void main() {} */` or `// void main`
        // above the real entry point can't be selected, and so `{`/`}` inside comments
        // don't skew the brace match. The mask is length-preserving, so offsets map 1:1
        // back onto `source` for the returned range.
        let masked = maskComments(source)
        guard let keywordRange = masked.range(of: "void main") else { return nil }
        guard let openBrace = masked.range(of: "{", range: keywordRange.upperBound..<masked.endIndex) else {
            return nil
        }
        var depth = 1
        var index = openBrace.upperBound
        while index < masked.endIndex && depth > 0 {
            let ch = masked[index]
            if ch == "{" { depth += 1 }
            else if ch == "}" { depth -= 1 }
            index = masked.index(after: index)
        }
        guard depth == 0 else { return nil }
        let lower = source.index(source.startIndex, offsetBy: masked.distance(from: masked.startIndex, to: keywordRange.lowerBound))
        let upper = source.index(source.startIndex, offsetBy: masked.distance(from: masked.startIndex, to: index))
        return lower..<upper
    }

    /// Replace `//` line comments and `/* */` block comments with spaces (newlines kept),
    /// preserving length so indices into the result map directly onto the input. Strings
    /// aren't tracked: GLSL has no string literals, so `//` and `/*` only ever open comments.
    static func maskComments(_ source: String) -> String {
        var result = Array(source)
        var i = 0
        let count = result.count
        while i < count {
            let ch = result[i]
            if ch == "/", i + 1 < count, result[i + 1] == "/" {
                var j = i
                while j < count, result[j] != "\n" {
                    result[j] = " "
                    j += 1
                }
                i = j
            } else if ch == "/", i + 1 < count, result[i + 1] == "*" {
                // Mask the two opener chars before scanning so the `*` of `/*`
                // can't be taken as the start of `*/` (`/*/` opens a comment).
                result[i] = " "
                result[i + 1] = " "
                var j = i + 2
                while j < count {
                    let closing = result[j] == "*" && j + 1 < count && result[j + 1] == "/"
                    if result[j] != "\n" { result[j] = " " }
                    j += 1
                    if closing {
                        if j < count, result[j] != "\n" { result[j] = " " }
                        j += 1
                        break
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(result)
    }

    /// Strip the `void main() { ... }` wrapper and rebuild it as Metal-friendly statements.
    static func translateMain(
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

    /// Rewrite every `g_Texture<N>.sample(linearSampler|repeatSampler, …)` read to the
    /// per-slot runtime sampler `wpeSampler<N>`, whose address mode (clamp/repeat) and
    /// filter (linear/nearest) are bound from the texture's TEXI flags in the executor —
    /// so scrolled tiling maps (water-normal, noise, flow) repeat instead of clamping to
    /// a frozen edge. `wpeSampler<N>` is a `main` argument and a threaded helper resource
    /// (`helperResources`), so it is in scope in both main and helper bodies; `#define`
    /// macro bodies expand into those same scopes. Runs LAST, after the `linearSampler`-
    /// keyed coordinate-narrowing and LOD rewrites, so those still match the literal name.
    static func rewriteSamplersToPerSlot(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(g_Texture(\d+)\.sample\()(?:linearSampler|repeatSampler)(\s*,)"#
        ) else { return source }
        let ns = source as NSString
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "$1wpeSampler$2$3"
        )
    }

}
#endif
