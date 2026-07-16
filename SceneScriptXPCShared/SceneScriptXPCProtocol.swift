import Foundation

enum SceneScriptXPCServiceIdentity {
    static let protocolVersion = 1
    static let serviceName = "Taijia.LiveWallpaper.SceneScriptService"
    static let productName = "SceneScriptXPCService.xpc"
}

@objc(LWSceneScriptXPCProtocol)
protocol SceneScriptXPCProtocol: AnyObject {
    func evaluateStaticTransforms(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    )
}

struct SceneScriptXPCVector3: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

enum SceneScriptXPCPropertyValue: Codable, Equatable, Sendable {
    case number(Double)
    case bool(Bool)
    case string(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case number
        case bool
        case string
    }

    private enum Kind: String, Codable {
        case number
        case bool
        case string
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .number:
            self = .number(try container.decode(Double.self, forKey: .number))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .bool))
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .number)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .bool)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .string)
        }
    }
}

struct SceneScriptXPCStaticTransformItem: Codable, Equatable, Sendable {
    let script: String
    let properties: [String: SceneScriptXPCPropertyValue]
    let seed: SceneScriptXPCVector3
}

struct SceneScriptXPCStaticTransformRequest: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let deadlineMilliseconds: Int
    let canvasWidth: Double
    let canvasHeight: Double
    let items: [SceneScriptXPCStaticTransformItem]
}

enum SceneScriptXPCFailure: String, Codable, Equatable, Sendable {
    case malformedRequest
    case unsupportedProtocol
    case resourceLimitExceeded
    case internalFailure
}

struct SceneScriptXPCStaticTransformResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let requestID: UUID
    let workerInstanceID: UUID
    let workerPID: Int32
    let durationNanoseconds: UInt64
    let results: [SceneScriptXPCVector3?]
    let failure: SceneScriptXPCFailure?
}
