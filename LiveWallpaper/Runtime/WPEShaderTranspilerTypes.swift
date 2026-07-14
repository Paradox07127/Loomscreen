#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

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
        parseAll(line: line).first
    }

    /// A single line may declare several comma-separated uniforms
    /// (`uniform float u_a, u_b;`). Each declarator becomes its own `Self`, sharing
    /// the base type and the trailing metadata comment; array suffixes are per
    /// declarator. Returns `[]` when the line is not a uniform declaration.
    static func parseAll(line: String) -> [Self] {
        guard line.hasPrefix("uniform ") else { return [] }
        let body = String(line.dropFirst("uniform ".count))
        if body.hasPrefix("sampler") { return [] }
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let semicolon = trimmed.firstIndex(of: ";") else { return [] }
        let decl = trimmed[..<semicolon]
        let comment = String(trimmed[trimmed.index(after: semicolon)...])
        let tokens = decl.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.count >= 2 else { return [] }
        let type = tokens[0]
        // The base type is the first token; everything after it is one or more
        // declarators. Split those on commas, not the whole line, so the type isn't
        // duplicated onto each name.
        let declaratorSource = tokens[1...].joined(separator: " ")
        let metadata = Self.parseMetadataComment(comment)
        let metal = mapType(type)
        return declaratorSource.split(separator: ",").compactMap { declarator in
            var name = declarator.trimmingCharacters(in: .whitespaces)
            var arrayLength: Int?
            if let bracket = name.firstIndex(of: "[") {
                let core = name[..<bracket].trimmingCharacters(in: .whitespaces)
                let after = name[name.index(after: bracket)...]
                if let close = after.firstIndex(of: "]") {
                    let lengthString = String(after[..<close]).trimmingCharacters(in: .whitespaces)
                    arrayLength = Int(lengthString)
                }
                name = core
            }
            guard !name.isEmpty else { return nil }
            return Self(
                type: type,
                name: name,
                metalType: metal,
                arrayLength: arrayLength,
                materialName: metadata.materialName,
                defaultValue: metadata.defaultValue
            )
        }
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
