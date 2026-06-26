import Foundation

public enum WPEValueParser {
    public static func comboMap(_ raw: Any?, boolAsNumber: Bool = false) -> [String: Int] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]
        for (key, value) in dict {
            if let intValue = int(value, boolAsNumber: boolAsNumber) {
                result[key] = intValue
            }
        }
        return result
    }

    /// Accepts both forms WPE writes: the plain `{name: value}` dictionary and
    /// the structured array `[{name:…, value:…}]` used by effect-instance
    /// overrides (entries may carry `value` or `default`).
    public static func shaderConstants(
        _ raw: Any?,
        boolAsNumber: Bool = false
    ) -> [String: WPESceneShaderConstantValue] {
        var result: [String: WPESceneShaderConstantValue] = [:]
        if let dict = raw as? [String: Any] {
            for (key, value) in dict {
                if let parsed = shaderConstant(value, boolAsNumber: boolAsNumber) {
                    result[key] = parsed
                }
            }
            return result
        }
        if let array = raw as? [Any] {
            for entry in array {
                guard let dict = entry as? [String: Any],
                      let name = shaderConstantEntryName(in: dict) else { continue }
                let value = dict.keys.contains("value") ? dict["value"]
                    : dict.keys.contains("default") ? dict["default"]
                    : nil
                if let parsed = shaderConstant(value, boolAsNumber: boolAsNumber) {
                    result[name] = parsed
                }
            }
        }
        return result
    }

    /// `constantshadervalues` array entry uniform name: `name` / `uniform` / `material`, first non-empty wins.
    public static func shaderConstantEntryName(in dict: [String: Any]) -> String? {
        for key in ["name", "uniform", "material"] {
            if let string = dict[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    public static func shaderConstant(
        _ raw: Any?,
        boolAsNumber: Bool = false
    ) -> WPESceneShaderConstantValue? {
        if let bool = strictBool(raw) {
            return .bool(bool)
        }
        if let animated = animatedValue(raw, boolAsNumber: boolAsNumber) {
            return .animated(animated)
        }
        if let dict = raw as? [String: Any], dict["value"] != nil {
            return shaderConstant(dict["value"], boolAsNumber: boolAsNumber)
        }
        if let vector = numberVector(raw, boolAsNumber: boolAsNumber) {
            return .vector(vector)
        }
        if let value = double(raw, boolAsNumber: boolAsNumber) {
            return .number(value)
        }
        if let string = raw as? String {
            return .string(string)
        }
        return nil
    }

    public static func animatedValue(
        _ raw: Any?,
        boolAsNumber: Bool = false
    ) -> WPESceneAnimatedValue? {
        guard let dict = raw as? [String: Any],
              let animationDict = dict["animation"] as? [String: Any] else {
            return nil
        }
        let tracks = animationTracks(in: animationDict, boolAsNumber: boolAsNumber)
        guard !tracks.isEmpty else { return nil }

        let options = animationDict["options"] as? [String: Any] ?? [:]
        let valueRaw = dict["value"] ?? animationDict["previewvalue"]
        let vectorFallback = numberVector(valueRaw, boolAsNumber: boolAsNumber, minimumCount: 1)
            ?? numberVector(animationDict["previewvalue"], boolAsNumber: boolAsNumber, minimumCount: 1)
        let scalarFallback = double(valueRaw, boolAsNumber: boolAsNumber)
            ?? double(animationDict["previewvalue"], boolAsNumber: boolAsNumber)
            ?? vectorFallback?.first

        return WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: tracks,
                fps: double(options["fps"], boolAsNumber: boolAsNumber) ?? 30,
                length: double(options["length"], boolAsNumber: boolAsNumber) ?? 0,
                mode: (options["mode"] as? String) ?? "single",
                wrapLoop: bool(options["wraploop"]) ?? false
            ),
            scalarFallback: scalarFallback,
            vectorFallback: vectorFallback
        )
    }

    private static func animationTracks(
        in animationDict: [String: Any],
        boolAsNumber: Bool
    ) -> [[WPESceneAnimationKeyframe]] {
        let trackKeys = animationDict.keys.compactMap { key -> (name: String, index: Int)? in
            guard key.first == "c",
                  let index = Int(key.dropFirst()) else {
                return nil
            }
            return (key, index)
        }.sorted { $0.index < $1.index }

        return trackKeys.compactMap { key in
            guard let rawFrames = animationDict[key.name] as? [Any] else {
                return nil
            }
            let frames = rawFrames.compactMap { raw -> WPESceneAnimationKeyframe? in
                guard let dict = raw as? [String: Any],
                      let frame = double(dict["frame"], boolAsNumber: boolAsNumber),
                      let value = double(dict["value"], boolAsNumber: boolAsNumber) else {
                    return nil
                }
                return WPESceneAnimationKeyframe(frame: frame, value: value)
            }
            return frames.isEmpty ? nil : frames
        }
    }

    public static func numberVector(
        _ raw: Any?,
        boolAsNumber: Bool = false,
        minimumCount: Int = 2
    ) -> [Double]? {
        if let array = raw as? [Any] {
            let values = array.compactMap { double($0, boolAsNumber: boolAsNumber) }
            return values.count == array.count && values.count >= minimumCount ? values : nil
        }
        if let string = raw as? String {
            let pieces = string.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            let values = pieces.compactMap { Double($0) }
            return values.count == pieces.count && values.count >= minimumCount ? values : nil
        }
        return nil
    }

    public static func vector3(_ raw: Any?, boolAsNumber: Bool = false) -> SIMD3<Double>? {
        // WPE binds a transform component (scale/origin/angles) to a user property
        // as {"user": "newpropertyN", "value": "0.5 0.5 0.5"}; the resolved value
        // lives in `value`. Unwrap it (matching `shaderConstant`) so a property-bound
        // transform resolves instead of silently falling back to the default — e.g.
        // an audio-bar composelayer scale of 0.5 was parsing as 1.0, doubling the box.
        if let dict = raw as? [String: Any], let value = dict["value"] {
            return vector3(value, boolAsNumber: boolAsNumber)
        }
        if let values = numberVector(raw, boolAsNumber: boolAsNumber) {
            let z = values.count >= 3 ? values[2] : 0
            return SIMD3<Double>(values[0], values[1], z)
        }
        if let dict = raw as? [String: Any] {
            let x = double(dict["x"], boolAsNumber: boolAsNumber) ?? 0
            let y = double(dict["y"], boolAsNumber: boolAsNumber) ?? 0
            let z = double(dict["z"], boolAsNumber: boolAsNumber) ?? 0
            if x == 0 && y == 0 && z == 0 { return nil }
            return SIMD3<Double>(x, y, z)
        }
        return nil
    }

    public static func double(_ raw: Any?, boolAsNumber: Bool = false) -> Double? {
        // A JSON boolean bridges to a CFBoolean-backed NSNumber, so it would otherwise
        // slip through the `as? NSNumber` path as 0/1 even when the caller asked for a
        // bool to parse as nil. Resolve it up front: 1/0 only when boolAsNumber, else nil.
        if let bool = strictBool(raw) {
            return boolAsNumber ? (bool ? 1 : 0) : nil
        }
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let double = raw as? Double {
            return double
        }
        if let int = raw as? Int {
            return Double(int)
        }
        if let string = raw as? String {
            return Double(string)
        }
        return nil
    }

    public static func int(_ raw: Any?, boolAsNumber: Bool = false) -> Int? {
        // Mirror `double`: a CFBoolean-backed NSNumber must not slip through the
        // `as? NSNumber` path as 0/1 when the caller didn't opt into boolAsNumber.
        if let bool = strictBool(raw) {
            return boolAsNumber ? (bool ? 1 : 0) : nil
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let int = raw as? Int {
            return int
        }
        if let string = raw as? String {
            return Int(string)
        }
        return nil
    }

    public static func bool(_ raw: Any?) -> Bool? {
        if let bool = raw as? Bool {
            return bool
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        if let string = raw as? String {
            switch string.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    public static func strictBool(_ raw: Any?) -> Bool? {
        if let number = raw as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
        }
        return raw as? Bool
    }
}
