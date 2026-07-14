import Foundation

// MARK: - Monitor wallpaper data contract (schema v2)
// These Codable structs are the single snapshot contract consumed by the
// native widget board and the HUD — key names are load-bearing; never rename
// without bumping `schemaVersion`. Every v2 field is Optional so a v1
// producer round-trips unchanged.
//
// Privacy invariant: status/counts/tool NAMES only. Never prompt text,
// tool arguments, command output, or file diffs.

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

    // v2 Fleet signals — all optional (schemaVersion 2)
    /// Recent event timestamps (epoch seconds, ≤60 kept) for the tick track.
    var recentEventTimes: [Double]?
    /// Epoch seconds when status flipped to needsInput ("who is waiting on me").
    var waitSince: Double?
    /// Last-turn input tokens ÷ model context window (0…1); nil if unknown model.
    var contextUsedPercent: Double?
    /// Derived anomaly flag: "toolLoop" | "stale". Metadata-only derivation.
    var warning: String?
    var recentTools: [MonitorAgentToolEvent]?
    var worktreeName: String?
}

/// One tool invocation, name-only (privacy invariant: never arguments).
struct MonitorAgentToolEvent: Codable, Sendable, Equatable {
    var name: String
    var at: Double                    // epoch seconds
    var ok: Bool?                     // false when the result carried is_error
}

struct MonitorProcessSample: Codable, Sendable, Equatable {
    var name: String
    var cpuPercent: Double
    var memBytes: UInt64
    var pid: Int?
    var bundleID: String?
    var kind: String?                 // app | background | system
    /// Per-app disk I/O rates (rusage_info deltas); only set on `topIOProcesses`.
    var ioReadBytesPerSec: Double?
    var ioWriteBytesPerSec: Double?
}

// MARK: System hardware identity + per-component detail (v2)

struct MonitorCPUCoreGroup: Codable, Sendable, Equatable {
    /// Real `hw.perflevelN.name` ("Super"/"Performance"/"Efficiency"/…) —
    /// never a hardcoded P/E guess; "CPU" fallback when unavailable.
    var name: String
    var physicalCount: Int
}

struct MonitorCPUInfo: Codable, Sendable, Equatable {
    var deviceName: String?           // machdep.cpu.brand_string
    var coreCount: Int?               // hw.physicalcpu
    var coreGroups: [MonitorCPUCoreGroup]?
}

struct MonitorMemoryBreakdown: Codable, Sendable, Equatable {
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var cachedFilesBytes: UInt64 = 0
}

struct MonitorNetworkInterface: Codable, Sendable, Equatable {
    var name: String                  // "en0"
    var rxBytesPerSec: Double = 0
    var txBytesPerSec: Double = 0
    var rxPacketsPerSec: Double?
    var txPacketsPerSec: Double?
    /// Cumulative since boot (if_data counters) — renderers show deltas.
    var rxErrors: UInt64?
    var txErrors: UInt64?
    var rxDrops: UInt64?
    var addresses: [String]?          // private IPs only (AF_INET/AF_INET6)
    var isActive: Bool?               // NWPath-chosen or highest-traffic
}

struct MonitorNetworkPath: Codable, Sendable, Equatable {
    var status: String = "unknown"    // satisfied | unsatisfied | requiresConnection | unknown
    var interfaceType: String?        // wifi | wired | cellular | other
    var isConstrained: Bool?
    var isExpensive: Bool?
}

struct MonitorAccessoryBattery: Codable, Sendable, Equatable {
    var name: String
    var kind: String?                 // mouse | keyboard | trackpad | other
    var percent: Double
}

struct MonitorANEProcess: Codable, Sendable, Equatable {
    var name: String
    var footprintBytes: UInt64
}

/// B-tier readings, only populated by the Pro-direct sensor helper (W-F).
/// Absent field == this machine/OS generation doesn't expose it; renderers
/// must degrade gracefully, never show 0 for a missing sensor.
struct MonitorSensorReadings: Codable, Sendable, Equatable {
    var cpuTempC: Double?
    var gpuTempC: Double?
    var socTempC: Double?
    var cpuPowerW: Double?
    var gpuPowerW: Double?
    var aneWatts: Double?
    var fanRPM: [Double]?
    var perCoreFreqMHz: [Double]?
    var dramReadBytesPerSec: Double?
    var dramWriteBytesPerSec: Double?
    var stale: Bool?
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

    // v2 additions — all optional (schemaVersion 2)
    var cpuInfo: MonitorCPUInfo?
    var cpuLoadAvg: [Double]?         // 1 / 5 / 15 min
    var memBreakdown: MonitorMemoryBreakdown?
    var gpuDeviceName: String?
    var gpuCoreCount: Int?
    var gpuSampledAt: Double?         // GPU sampled ~6s; renderers dim stale
    var gpuRendererUtil: Double?      // 0…1
    var gpuTilerUtil: Double?         // 0…1
    var netInterfaces: [MonitorNetworkInterface]?
    var netPath: MonitorNetworkPath?
    var batteryIsCharged: Bool?
    var powerSource: String?          // battery | ac | ups
    var batteryMinutesRemaining: Double?   // IOPS -1 (calculating) maps to nil
    var batteryMinutesToFull: Double?
    var lowPowerMode: Bool?
    var accessories: [MonitorAccessoryBattery]?
    var aneProcesses: [MonitorANEProcess]?
    var aneActive: Bool?
    var sensors: MonitorSensorReadings?
    /// Top apps by disk I/O rate (same aggregation-by-app as `topProcesses`,
    /// ranked by read+write instead of CPU). Demand-gated by the Disk widget.
    var topIOProcesses: [MonitorProcessSample]?
    /// GPU-owned system memory in use (Apple Silicon `PerformanceStatistics`
    /// "In use system memory"); nil where the driver doesn't publish it.
    var gpuMemUsedBytes: UInt64?
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
    /// so the Usage widget dims the quota block instead of presenting stale
    /// percentages as current.
    var limitsStale: Bool?

    // v2 additions — all optional (schemaVersion 2)
    var perModel: [MonitorUsageModelBreakdown]?
    var dailyActivity: [MonitorUsageDayBucket]?
    var tokenBurnRatePerHour: Double?
    var costBurnRatePerHour: Double?
}

struct MonitorUsageModelBreakdown: Codable, Sendable, Equatable {
    var model: String
    var tokens: MonitorTokenTotals = .zero
    var costUSD: Double?
}

struct MonitorUsageDayBucket: Codable, Sendable, Equatable {
    var day: String                   // "YYYY-MM-DD" local calendar
    var tokens: MonitorTokenTotals = .zero
    var costUSD: Double?
}

/// Per-source pipeline health, surfaced by the settings pane and the AI
/// widgets' why-no-data empty states ("unauthorized / stale / ok").
struct MonitorSourceHealth: Codable, Sendable, Equatable {
    var sourceID: String
    var state: String                 // ok | stale | unauthorized | error | off
    var detail: String?
    var lastUpdateAt: Double?
}

/// The single object renderers see. `nil` module == module disabled;
/// agent widgets render an unauthorized / empty state when `agents == nil`.
struct MonitorSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 2
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
