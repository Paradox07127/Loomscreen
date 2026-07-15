#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

extension WPEShaderTranspiler {
    // MARK: - Helper resource threading

    private struct HelperResource: Hashable {
        let name: String
        let parameterType: String
    }

    struct HelperFunction {
        let name: String
        let parameterRange: Range<String.Index>
        let bodyRange: Range<String.Index>
    }

    /// Metal helper functions live outside `wpe_translated_fragment`, so they cannot see
    /// the sampler/uniform aliases emitted inside the fragment body. Thread those aliases
    /// through helper parameters and through helper call sites.
    static func rewriteHelperResourceAccess(
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
        // Texture-call rewriting turns a helper-body `texture(g_TextureN, uv)`
        // into `g_TextureN.sample(wpeSamplerN, uv)` — the per-slot sampler
        // STATE must be threaded alongside the texture or the helper references
        // an undeclared identifier (godrays_gaussian's blur helpers).
        let samplerStateResources = samplers.compactMap { decl -> HelperResource? in
            guard let slot = textureSlot(for: decl.name) else { return nil }
            return HelperResource(name: "wpeSampler\(slot)", parameterType: "sampler")
        }
        let uniformResources = uniforms.map {
            HelperResource(name: $0.name, parameterType: helperParameterType(for: $0))
        }
        let mutableGlobalResources = mutableGlobals.map {
            HelperResource(name: $0.name, parameterType: $0.helperParameterType)
        }
        return samplerResources + samplerStateResources + uniformResources + mutableGlobalResources
    }

    private static func helperMacroDependencies(
        in source: String,
        resources: [HelperResource]
    ) -> [String: Set<String>] {
        // Fold `\`-continued macro bodies onto one line first: the body pattern is
        // single-line (`[^\n]*`), so without folding a resource referenced on a
        // continuation line (`#define S(uv) \` <nl> `texture(g_Texture0, uv)`) is
        // missed and never threaded into the helper. Only used for dependency
        // scanning, so collapsing continuations here doesn't affect emitted source.
        let folded = source.replacingOccurrences(
            of: #"\\[ \t]*\r?\n"#,
            with: " ",
            options: .regularExpression
        )
        let pattern = #"(?m)^\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\b([^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [:]
        }
        let matches = regex.matches(in: folded, range: NSRange(folded.startIndex..., in: folded))
        var dependencies: [String: Set<String>] = [:]
        var bodies: [String: String] = [:]

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let nameRange = Range(match.range(at: 1), in: folded),
                  let bodyRange = Range(match.range(at: 2), in: folded) else {
                continue
            }
            let name = String(folded[nameRange])
            let body = String(folded[bodyRange])
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

    static func parseHelperFunctions(in source: String) -> [HelperFunction] {
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
            // Skip `//` and `/* */` regions so a `}`/`)` inside a comment (e.g. a
            // `// }` in a helper body) can't close the delimiter early and truncate
            // the body — returned index still maps onto `source`.
            let next = source.index(after: index)
            if ch == "/", next < source.endIndex, source[next] == "/" {
                index = next
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            if ch == "/", next < source.endIndex, source[next] == "*" {
                index = source.index(after: next)
                while index < source.endIndex {
                    if source[index] == "*",
                       source.index(after: index) < source.endIndex,
                       source[source.index(after: index)] == "/" {
                        index = source.index(index, offsetBy: 2)
                        break
                    }
                    index = source.index(after: index)
                }
                continue
            }
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

    static func isIdentifierStart(_ ch: Character) -> Bool {
        ch == "_" || ch.isLetter
    }

    static func isIdentifierCharacter(_ ch: Character) -> Bool {
        ch == "_" || ch.isLetter || ch.isNumber
    }

}
#endif
