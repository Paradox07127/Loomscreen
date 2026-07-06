import Foundation

// MARK: - Monitor wallpaper data contract
// These Codable structs ARE the JSON contract pushed into the bundled
// dashboard via `window.__monitorPush(json)` — key names are load-bearing
// for the JS side; never rename without bumping `schemaVersion`.

enum MonitorAgentProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

enum MonitorAgentStatus: String, Codable, Sendable {
    case running
    case needsInput
    case idle
    case ended
    case unknown

    /// Fleet-level aggregation: any blocked > any running > all idle.
    var attentionPriority: Int {
        switch self {
        case .needsInput: return 4
        case .running: return 3
        case .idle: return 2
        case .unknown: return 1
        case .ended: return 0
        }
    }
}

struct MonitorTokenTotals: Codable, Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    static let zero = MonitorTokenTotals()

    static func + (lhs: Self, rhs: Self) -> Self {
        MonitorTokenTotals(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite
        )
    }
}

/// One live/recent agent session, already normalized + privacy-redacted.
/// `statusDetail` must only ever carry tool names / short verbs
/// ("Bash: xcodebuild", "Edit"), never prompt or output text.
struct MonitorAgentSessionState: Codable, Sendable, Equatable, Identifiable {
    var id: String                    // "<provider>:<sessionID>"
    var provider: MonitorAgentProvider
    var projectName: String           // display name only, no full path
    var status: MonitorAgentStatus
    var statusDetail: String?
    var model: String?
    var gitBranch: String?
    var startedAt: Double?            // epoch seconds
    var lastEventAt: Double           // epoch seconds
    var processAlive: Bool
    var turnCount: Int = 0
    var tokens: MonitorTokenTotals = .zero
    var costUSD: Double?
}

struct MonitorProcessSample: Codable, Sendable, Equatable {
    var name: String
    var cpuPercent: Double
    var memBytes: UInt64
}

struct MonitorSystemSnapshot: Codable, Sendable, Equatable {
    var cpuTotal: Double = 0          // 0…1 system-wide
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var perCore: [Double]?
    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    var memPressure: String = "normal"   // normal | warn | critical
    var swapUsedBytes: UInt64?
    var gpuUsage: Double?
    var thermalState: String = "nominal" // nominal | fair | serious | critical
    var netRxBytesPerSec: Double = 0
    var netTxBytesPerSec: Double = 0
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0
    var batteryLevel: Double?
    var batteryCharging: Bool?
    var uptimeSeconds: Double = 0
    var loadAverage1: Double?
    var topProcesses: [MonitorProcessSample]?
}

struct MonitorProviderUsage: Codable, Sendable, Equatable {
    var costTodayUSD: Double?
    var tokensToday: MonitorTokenTotals?
}

struct MonitorUsageSnapshot: Codable, Sendable, Equatable {
    var costTodayUSD: Double?
    var tokensToday: MonitorTokenTotals?
    var perProvider: [String: MonitorProviderUsage]?
    var fiveHourUsedPercent: Double?
    var fiveHourResetsAt: Double?
    var weekUsedPercent: Double?
    var weekResetsAt: Double?
    /// True when the rate-limit capture file is older than its freshness window,
    /// so the dashboard dims the quota block instead of presenting stale
    /// percentages as current.
    var limitsStale: Bool?
}

/// Per-source pipeline health, surfaced in the dashboard footer and the
/// settings pane ("未授权 / stale / ok").
struct MonitorSourceHealth: Codable, Sendable, Equatable {
    var sourceID: String
    var state: String                 // ok | stale | unauthorized | error | off
    var detail: String?
    var lastUpdateAt: Double?
}

/// The single object renderers see. `nil` module == module disabled;
/// the dashboard must render a system-only hero layout when `agents == nil`.
struct MonitorSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var timestamp: Double = 0
    var system: MonitorSystemSnapshot?
    var agents: [MonitorAgentSessionState]?
    var usage: MonitorUsageSnapshot?
    var health: [MonitorSourceHealth]?

    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func jsonString() -> String? {
        guard let data = try? Self.jsonEncoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Source plumbing

/// Sink the hub exposes to sources. Sources push partial updates whenever
/// they have news; the hub recomposes + publishes downstream at its own pace.
protocol MonitorSnapshotSink: Actor {
    func updateSystem(_ snapshot: MonitorSystemSnapshot) async
    func updateAgents(sourceID: String, sessions: [MonitorAgentSessionState]) async
    func updateUsage(_ usage: MonitorUsageSnapshot) async
    func updateHealth(_ health: MonitorSourceHealth) async
}

protocol MonitorDataSource: Sendable {
    var sourceID: String { get }
    func start(sink: any MonitorSnapshotSink) async
    func stop() async
}
