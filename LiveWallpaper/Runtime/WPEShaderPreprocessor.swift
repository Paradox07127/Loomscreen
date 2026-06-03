#if !LITE_BUILD
import CryptoKit
import Foundation

/// Pure-Swift frontend for the WPE shader dialect. Runs before the Swift
/// transpiler: parses `// [COMBO]` / `// [BIND]` annotations, resolves
/// `#include "header.h"` against the scene's `shaders/` directory, applies
/// WPE→canonical-GLSL macro fixups, and bakes combo `#define`s into the
/// preamble so translation only has to deal with vanilla GLSL.
///
/// Every transformation here is portable and easy to test, which is exactly
/// what we want — by the time translation runs, all WPE-specific quirks
/// have been resolved.
struct WPEShaderPreprocessor {

    /// Files looked up via `#include`. Keyed by relative include path,
    /// e.g. `"common.h"`. Provided by the scene's pipeline builder.
    typealias IncludeResolver = (_ path: String, _ requestedBy: String) -> String?

    let includeResolver: IncludeResolver

    init(includeResolver: @escaping IncludeResolver) {
        self.includeResolver = includeResolver
    }

    func process(
        shaderName: String,
        vertexSource: String,
        fragmentSource: String,
        comboValues: [String: Int],
        materialTextureBindings: [Int: String]
    ) throws -> WPEShaderCompileRequest {
        let vertResult = try processStage(
            stage: .vertex,
            shaderName: shaderName,
            source: vertexSource,
            comboValues: comboValues
        )
        let fragResult = try processStage(
            stage: .fragment,
            shaderName: shaderName,
            source: fragmentSource,
            comboValues: comboValues
        )

        var combinedBindings = vertResult.bindings.merging(fragResult.bindings) { _, fragmentValue in fragmentValue }
        combinedBindings.merge(materialTextureBindings) { _, materialValue in materialValue }

        let merged = mergeComboDefaults(
            from: vertResult.combos.merging(fragResult.combos) { lhs, _ in lhs },
            overriddenBy: comboValues
        )

        let hash = Self.stableHash(
            shaderName: shaderName,
            vertexSource: vertexSource,
            fragmentSource: fragmentSource,
            comboValues: merged
        )

        return WPEShaderCompileRequest(
            shaderName: shaderName,
            processedVertexSource: vertResult.source,
            processedFragmentSource: fragResult.source,
            sourceHash: hash,
            comboValues: merged,
            textureBindings: combinedBindings
        )
    }

    // MARK: - Per-stage processing

    enum Stage {
        case vertex, fragment
    }

    struct StageResult {
        let source: String
        let combos: [String: WPEComboDeclaration]
        let bindings: [Int: String]
    }

    func processStage(
        stage: Stage,
        shaderName: String,
        source: String,
        comboValues: [String: Int]
    ) throws -> StageResult {
        var combos: [String: WPEComboDeclaration] = [:]
        var bindings: [Int: String] = [:]
        var includedAlready = Set<String>()
        let resolved = try resolveIncludes(
            // Normalize CRLF/CR → LF first. Swift treats "\r\n" as one grapheme,
            // so the line-based passes below (`split(separator: "\n")`) would see
            // a CRLF file as a SINGLE line — collapsing the whole shader onto its
            // first line. When that line is `#include "…"` the entire body is
            // swallowed as part of the include and silently dropped. WPE shaders
            // (and most Windows-authored workshop shaders) ship CRLF.
            source: Self.normalizeNewlines(source),
            requestedBy: shaderName,
            visited: &includedAlready
        )
        let scanned = scanAnnotations(source: resolved, combos: &combos, bindings: &bindings)
        let canonical = applyMacroFixups(source: scanned, stage: stage)

        let merged = mergeComboDefaults(from: combos, overriddenBy: comboValues)
        let preamble = makePreamble(
            stage: stage,
            comboValues: merged
        )
        return StageResult(
            source: preamble + "\n" + canonical,
            combos: combos,
            bindings: bindings
        )
    }

    /// Collapse CRLF and lone-CR line endings to LF so every downstream
    /// line-based pass splits consistently regardless of the shader's authoring
    /// platform.
    static func normalizeNewlines(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Includes

    private func resolveIncludes(
        source: String,
        requestedBy: String,
        visited: inout Set<String>
    ) throws -> String {
        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") {
                let path = Self.extractIncludePath(from: trimmed)
                guard let path else {
                    lines.append(String(line))
                    continue
                }
                if visited.contains(path) {
                    continue
                }
                visited.insert(path)
                guard let payload = includeResolver(path, requestedBy) else {
                    throw WPEShaderCompilerError.glslPreprocessFailed(
                        "missing include '\(path)' requested by '\(requestedBy)'"
                    )
                }
                let inner = try resolveIncludes(
                    // Included files carry their own line endings (often CRLF) —
                    // normalize before recursing so they split into real lines.
                    source: Self.normalizeNewlines(payload),
                    requestedBy: path,
                    visited: &visited
                )
                lines.append("// [BEGIN INCLUDE \(path)]")
                lines.append(inner)
                lines.append("// [END INCLUDE \(path)]")
            } else {
                lines.append(String(line))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func extractIncludePath(from line: String) -> String? {
        guard let openIndex = line.firstIndex(where: { $0 == "\"" || $0 == "<" }) else {
            return nil
        }
        let opener = line[openIndex]
        let closer: Character = opener == "<" ? ">" : "\""
        let afterOpen = line.index(after: openIndex)
        guard let closeIndex = line[afterOpen...].firstIndex(of: closer) else {
            return nil
        }
        return String(line[afterOpen..<closeIndex])
    }

    // MARK: - Annotations

    private func scanAnnotations(
        source: String,
        combos: inout [String: WPEComboDeclaration],
        bindings: inout [Int: String]
    ) -> String {
        var output: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let combo = WPEComboDeclaration.parse(line: trimmed) {
                combos[combo.combo] = combo
                output.append("// combo \(combo.combo)=default(\(combo.defaultValue))")
                continue
            }
            if let bind = WPEBindDeclaration.parse(line: trimmed) {
                bindings[bind.slot] = bind.name
                output.append("// bind \(bind.slot)=\(bind.name)")
                continue
            }
            output.append(String(line))
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Macro fixups

    /// Apply WPE→canonical-GLSL macro substitutions.
    private func applyMacroFixups(source: String, stage: Stage) -> String {
        var s = source

        s = s.replacingOccurrences(of: "texSample2DLod(", with: "textureLod(")
        s = s.replacingOccurrences(of: "texSample2D(", with: "texture(")
        s = s.replacingOccurrences(of: "texSampleNorm2D(", with: "texture(")

        if stage == .fragment, s.contains("gl_FragColor") {
            s = "out vec4 wpe_fragColor;\n" + s.replacingOccurrences(of: "gl_FragColor", with: "wpe_fragColor")
        }

        return s
    }

    // MARK: - Combos

    private func mergeComboDefaults(
        from declarations: [String: WPEComboDeclaration],
        overriddenBy values: [String: Int]
    ) -> [String: Int] {
        var merged: [String: Int] = [:]
        for (name, declaration) in declarations {
            merged[name] = declaration.defaultValue
        }
        for (name, value) in values {
            merged[name] = value
        }
        return merged
    }

    private func makePreamble(stage: Stage, comboValues: [String: Int]) -> String {
        var lines: [String] = ["#version 410 core"]
        for name in comboValues.keys.sorted() {
            lines.append("#define \(name) \(comboValues[name]!)")
        }
        switch stage {
        case .vertex:
            lines.append("// stage: vertex")
        case .fragment:
            lines.append("// stage: fragment")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Hashing

    static func stableHash(
        shaderName: String,
        vertexSource: String,
        fragmentSource: String,
        comboValues: [String: Int]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(shaderName.utf8))
        hasher.update(data: Data(vertexSource.utf8))
        hasher.update(data: Data(fragmentSource.utf8))
        for key in comboValues.keys.sorted() {
            hasher.update(data: Data(key.utf8))
            hasher.update(data: Data(String(comboValues[key]!).utf8))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Annotation parsers

struct WPEComboDeclaration: Equatable {
    let combo: String
    let material: String?
    let comboType: String?
    let defaultValue: Int

    static func parse(line: String) -> Self? {
        guard let body = stripPrefix(line, prefix: "// [COMBO]")
            ?? stripPrefix(line, prefix: "//[COMBO]") else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(body.utf8),
            options: [.allowFragments]
        ) as? [String: Any] else {
            return nil
        }
        guard let combo = json["combo"] as? String, !combo.isEmpty else { return nil }
        let defaultValue: Int = {
            if let i = json["default"] as? Int { return i }
            if let d = json["default"] as? Double { return Int(d) }
            if let s = json["default"] as? String, let i = Int(s) { return i }
            return 0
        }()
        return Self(
            combo: combo,
            material: json["material"] as? String,
            comboType: json["type"] as? String,
            defaultValue: defaultValue
        )
    }
}

struct WPEBindDeclaration: Equatable {
    let slot: Int
    let name: String

    static func parse(line: String) -> Self? {
        guard let body = stripPrefix(line, prefix: "// [BIND]")
            ?? stripPrefix(line, prefix: "//[BIND]") else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(body.utf8),
            options: [.allowFragments]
        ) as? [String: Any] else {
            return nil
        }
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let slot: Int = {
            if let i = json["index"] as? Int { return i }
            if let i = json["slot"] as? Int { return i }
            return 0
        }()
        return Self(slot: slot, name: name)
    }
}

private func stripPrefix(_ string: String, prefix: String) -> String? {
    guard string.hasPrefix(prefix) else { return nil }
    return String(string.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
}
#endif
