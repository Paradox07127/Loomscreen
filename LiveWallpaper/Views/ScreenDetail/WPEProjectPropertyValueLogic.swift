#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Shared value logic for the web (`WPEProjectCustomSettingsCard`) and scene (`WPESceneCustomSettingsCard`) settings inspectors: slider normalization, number formatting, color codecs, and default comparison.
enum WPEProjectPropertyValueLogic {
    typealias Property = WallpaperEngineProjectPropertySchema.Property

    static func value(
        for property: Property,
        in values: [String: WallpaperEngineProjectPropertyValue]
    ) -> WallpaperEngineProjectPropertyValue {
        values[property.key] ?? fallbackValue(for: property)
    }

    static func fallbackValue(for property: Property) -> WallpaperEngineProjectPropertyValue {
        switch property.type {
        case .bool:
            return .bool(false)
        case .slider:
            return .number(property.minimum ?? 0)
        case .combo:
            return property.options.first?.value ?? .string("")
        case .color:
            return .string("1 1 1")
        case .textinput, .file, .directory, .text, .group, .unsupported:
            return .string("")
        }
    }

    // MARK: - Slider normalization

    static func sliderRange(for property: Property) -> ClosedRange<Double> {
        let lower = property.minimum ?? 0
        let upper = property.maximum ?? max(100, lower + 1)
        return upper > lower ? lower...upper : lower...(lower + 1)
    }

    static func sliderStep(for property: Property) -> Double {
        if let step = property.step, step > 0 { return step }
        return property.fraction ? 0.1 : 1
    }

    static func normalizedSliderValue(_ raw: Double, for property: Property) -> Double {
        let range = sliderRange(for: property)
        let clamped = clamp(raw, to: range)
        let step = sliderStep(for: property)
        guard step > 0 else { return clamped }
        let stepped = ((clamped - range.lowerBound) / step).rounded() * step + range.lowerBound
        return clamp(stepped, to: range)
    }

    static func formattedNumber(_ value: Double, for property: Property) -> String {
        let decimals = property.fraction ? min(max(property.precision ?? 1, 0), 4) : 0
        return String(format: "%.\(decimals)f", value)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Default comparison

    /// Type-aware comparison that decides whether a freshly-edited value should be persisted as an override or treated as "back to default".
    static func matchesDefault(
        value: WallpaperEngineProjectPropertyValue,
        for property: Property
    ) -> Bool {
        guard let defaultValue = property.defaultValue else { return false }
        let tolerance = 1e-6

        switch (defaultValue, value) {
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs

        case (.number(let lhs), .number(let rhs)):
            return abs(lhs - rhs) <= tolerance

        case (.string(let lhs), .string(let rhs)):
            if property.type == .color {
                let lhsComponents = colorComponents(from: lhs)
                let rhsComponents = colorComponents(from: rhs)
                guard lhsComponents.count >= 3, rhsComponents.count >= 3 else {
                    return lhs == rhs
                }
                return zip(lhsComponents.prefix(3), rhsComponents.prefix(3))
                    .allSatisfy { abs($0 - $1) <= tolerance }
            }
            return lhs == rhs

        default:
            return defaultValue == value
        }
    }

    // MARK: - Color codecs

    /// Parses `"r g b"` / hex / `#rrggbb` into 3-4 normalized components so
    /// both equality and `cgColor(from:)` use one source of truth.
    static func colorComponents(from raw: String) -> [Double] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = decodeHexColor(trimmed) { return hex }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "," })
        let parsed = parts.compactMap { Double($0) }
        guard parsed.count >= 3 else { return [] }
        return parsed.prefix(4).map { min(max($0, 0), 1) }
    }

    /// Recognises WPE's other common color encoding (`"#rrggbb"`, `"#rrggbbaa"`, or bare `"rrggbb"`) so authors who used either notation interoperate with the SwiftUI ColorPicker round-trip.
    static func decodeHexColor(_ raw: String) -> [Double]? {
        var hex = raw.lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [6, 8].contains(hex.count),
              hex.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return nil
        }
        return stride(from: 0, to: hex.count, by: 2).map { offset -> Double in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            let byte = UInt8(hex[start..<end], radix: 16) ?? 0
            return Double(byte) / 255.0
        }
    }

    static func cgColor(from string: String) -> CGColor {
        let components = colorComponents(from: string)
        guard components.count >= 3 else {
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        }
        return CGColor(
            red: clamp01(components[0]),
            green: clamp01(components[1]),
            blue: clamp01(components[2]),
            alpha: 1
        )
    }

    static func colorString(from color: CGColor) -> String {
        let converted: CGColor
        if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
           let srgb = color.converted(to: colorSpace, intent: .defaultIntent, options: nil) {
            converted = srgb
        } else {
            converted = color
        }
        let components = converted.components ?? [1, 1, 1]
        let red: Double
        let green: Double
        let blue: Double
        if components.count >= 3 {
            red = Double(components[0])
            green = Double(components[1])
            blue = Double(components[2])
        } else {
            red = Double(components.first ?? 1)
            green = red
            blue = red
        }
        return "\(trimmedColor(red)) \(trimmedColor(green)) \(trimmedColor(blue))"
    }

    private static func trimmedColor(_ value: Double) -> String {
        String(format: "%.6g", clamp01(value))
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
#endif
