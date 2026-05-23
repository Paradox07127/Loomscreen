import Foundation

/// JSON-compatible value carried by Wallpaper Engine `project.json` user properties.
/// Web wallpapers receive values as `{ key: { value: ... } }` through
/// `window.wallpaperPropertyListener.applyUserProperties`.
public enum WallpaperEngineProjectPropertyValue: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Wallpaper Engine project property value must be bool, number, or string"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        case .bool:
            return nil
        }
    }

    public var stringValue: String {
        switch self {
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .string(let value):
            return value
        }
    }
}
