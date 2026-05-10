import Foundation

enum WPEValueParser {
    static func comboMap(_ raw: Any?, boolAsNumber: Bool = false) -> [String: Int] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]
        for (key, value) in dict {
            if let intValue = int(value, boolAsNumber: boolAsNumber) {
                result[key] = intValue
            }
        }
        return result
    }

    static func shaderConstants(
        _ raw: Any?,
        boolAsNumber: Bool = false
    ) -> [String: WPESceneShaderConstantValue] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var result: [String: WPESceneShaderConstantValue] = [:]
        for (key, value) in dict {
            if let parsed = shaderConstant(value, boolAsNumber: boolAsNumber) {
                result[key] = parsed
            }
        }
        return result
    }

    static func shaderConstant(
        _ raw: Any?,
        boolAsNumber: Bool = false
    ) -> WPESceneShaderConstantValue? {
        if let bool = raw as? Bool {
            return .bool(bool)
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

    static func numberVector(
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

    static func vector3(_ raw: Any?, boolAsNumber: Bool = false) -> SIMD3<Double>? {
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

    static func double(_ raw: Any?, boolAsNumber: Bool = false) -> Double? {
        if boolAsNumber, let bool = raw as? Bool {
            return bool ? 1 : 0
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

    static func int(_ raw: Any?, boolAsNumber: Bool = false) -> Int? {
        if boolAsNumber, let bool = raw as? Bool {
            return bool ? 1 : 0
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

    static func bool(_ raw: Any?) -> Bool? {
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
}
