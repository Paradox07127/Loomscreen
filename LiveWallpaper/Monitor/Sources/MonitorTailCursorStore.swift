import CryptoKit
import Foundation
import os

struct TailCursorState: Codable, Sendable, Equatable {
    var inode: UInt64
    var size: UInt64
    var offset: UInt64
}

struct SessionAggregateState: Codable, Sendable, Equatable {
    var provider: MonitorAgentProvider
    var sessionId: String?
    var projectName: String?
    var gitBranch: String?
    var model: String?
    var turnCount: Int
    var tokens: MonitorTokenTotals
    var startedAt: Double?
    var lastEventAt: Double?
    var lastToolName: String?
    var pendingToolUse: Bool?
    var lastAssistantStopReason: String?
    var sawPermissionRequest: Bool?
    var lastInboundAwaitsModel: Bool?
    var pendingApprovalAt: Double?
    var lastApprovalClearAt: Double?
    var lastStatusEventAt: Double?
    var lastTerminalEventIsTaskComplete: Bool?

    // Identifying session metadata (repo/branch/model/session id) is deliberately
    // NOT persisted: the on-disk cursor cache keeps only the resume status needed
    // to fold new transcript lines, and re-derives identity from the live tail on
    // the next poll. This keeps `MonitorTailCursors.json` free of the user's
    // project names, branches, and account/session identifiers.
    private enum CodingKeys: String, CodingKey {
        case provider
        case turnCount
        case tokens
        case startedAt
        case lastEventAt
        case lastToolName
        case pendingToolUse
        case lastAssistantStopReason
        case sawPermissionRequest
        case lastInboundAwaitsModel
        case pendingApprovalAt
        case lastApprovalClearAt
        case lastStatusEventAt
        case lastTerminalEventIsTaskComplete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(MonitorAgentProvider.self, forKey: .provider)
        self.turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        self.tokens = try container.decodeIfPresent(MonitorTokenTotals.self, forKey: .tokens) ?? .zero
        self.startedAt = try container.decodeIfPresent(Double.self, forKey: .startedAt)
        self.lastEventAt = try container.decodeIfPresent(Double.self, forKey: .lastEventAt)
        self.lastToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        self.pendingToolUse = try container.decodeIfPresent(Bool.self, forKey: .pendingToolUse)
        self.lastAssistantStopReason = try container.decodeIfPresent(String.self, forKey: .lastAssistantStopReason)
        self.sawPermissionRequest = try container.decodeIfPresent(Bool.self, forKey: .sawPermissionRequest)
        self.lastInboundAwaitsModel = try container.decodeIfPresent(Bool.self, forKey: .lastInboundAwaitsModel)
        self.pendingApprovalAt = try container.decodeIfPresent(Double.self, forKey: .pendingApprovalAt)
        self.lastApprovalClearAt = try container.decodeIfPresent(Double.self, forKey: .lastApprovalClearAt)
        self.lastStatusEventAt = try container.decodeIfPresent(Double.self, forKey: .lastStatusEventAt)
        self.lastTerminalEventIsTaskComplete = try container.decodeIfPresent(Bool.self, forKey: .lastTerminalEventIsTaskComplete)
        self.sessionId = nil
        self.projectName = nil
        self.gitBranch = nil
        self.model = nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(turnCount, forKey: .turnCount)
        try container.encode(tokens, forKey: .tokens)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(lastEventAt, forKey: .lastEventAt)
        try container.encodeIfPresent(lastToolName, forKey: .lastToolName)
        try container.encodeIfPresent(pendingToolUse, forKey: .pendingToolUse)
        try container.encodeIfPresent(lastAssistantStopReason, forKey: .lastAssistantStopReason)
        try container.encodeIfPresent(sawPermissionRequest, forKey: .sawPermissionRequest)
        try container.encodeIfPresent(lastInboundAwaitsModel, forKey: .lastInboundAwaitsModel)
        try container.encodeIfPresent(pendingApprovalAt, forKey: .pendingApprovalAt)
        try container.encodeIfPresent(lastApprovalClearAt, forKey: .lastApprovalClearAt)
        try container.encodeIfPresent(lastStatusEventAt, forKey: .lastStatusEventAt)
        try container.encodeIfPresent(lastTerminalEventIsTaskComplete, forKey: .lastTerminalEventIsTaskComplete)
    }

    init(
        provider: MonitorAgentProvider,
        sessionId: String?,
        projectName: String?,
        gitBranch: String?,
        model: String?,
        turnCount: Int,
        tokens: MonitorTokenTotals,
        startedAt: Double?,
        lastEventAt: Double?,
        lastToolName: String?,
        pendingToolUse: Bool? = nil,
        lastAssistantStopReason: String? = nil,
        sawPermissionRequest: Bool? = nil,
        lastInboundAwaitsModel: Bool? = nil,
        pendingApprovalAt: Double? = nil,
        lastApprovalClearAt: Double? = nil,
        lastStatusEventAt: Double? = nil,
        lastTerminalEventIsTaskComplete: Bool? = nil
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.model = model
        self.turnCount = turnCount
        self.tokens = tokens
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.lastToolName = lastToolName
        self.pendingToolUse = pendingToolUse
        self.lastAssistantStopReason = lastAssistantStopReason
        self.sawPermissionRequest = sawPermissionRequest
        self.lastInboundAwaitsModel = lastInboundAwaitsModel
        self.pendingApprovalAt = pendingApprovalAt
        self.lastApprovalClearAt = lastApprovalClearAt
        self.lastStatusEventAt = lastStatusEventAt
        self.lastTerminalEventIsTaskComplete = lastTerminalEventIsTaskComplete
    }
}

final class MonitorTailCursorStore: Sendable {
    private struct FilePayload: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var cursors: [String: TailCursorState]
        var aggregates: [String: SessionAggregateState]

        init(
            schemaVersion: Int = 1,
            cursors: [String: TailCursorState] = [:],
            aggregates: [String: SessionAggregateState] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.cursors = cursors
            self.aggregates = aggregates
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            self.cursors = try container.decodeIfPresent([String: TailCursorState].self, forKey: .cursors) ?? [:]
            self.aggregates = try container.decodeIfPresent([String: SessionAggregateState].self, forKey: .aggregates) ?? [:]
        }
    }

    private struct State: Sendable {
        var payload: FilePayload
        var dirty = false
        var saveTask: Task<Void, Never>?
    }

    private let fileURL: URL
    private let debounceNanoseconds: UInt64
    private let lock: OSAllocatedUnfairLock<State>

    init(directory: URL? = nil, debounceInterval: TimeInterval = 5) {
        let root = directory ?? Self.defaultApplicationSupportDirectory()
        self.fileURL = root.appendingPathComponent("MonitorTailCursors.json", isDirectory: false)
        self.debounceNanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
        self.lock = OSAllocatedUnfairLock(initialState: State(payload: Self.loadPayload(from: fileURL)))
    }

    func state(for url: URL) -> TailCursorState? {
        let key = Self.key(for: url)
        return lock.withLock { state in
            state.payload.cursors[key]
        }
    }

    func set(_ cursorState: TailCursorState, for url: URL) {
        let key = Self.key(for: url)
        lock.withLock { state in
            state.payload.cursors[key] = cursorState
        }
        save()
    }

    func remove(for url: URL) {
        let key = Self.key(for: url)
        lock.withLock { state in
            state.payload.cursors[key] = nil
            state.payload.aggregates[key] = nil
        }
        save()
    }

    func aggregate(for url: URL, provider: MonitorAgentProvider) -> SessionAggregateState? {
        let key = Self.key(for: url)
        return lock.withLock { state in
            guard let aggregate = state.payload.aggregates[key],
                  aggregate.provider == provider else {
                return nil
            }
            return aggregate
        }
    }

    func setAggregate(_ aggregate: SessionAggregateState, for url: URL) {
        let key = Self.key(for: url)
        lock.withLock { state in
            state.payload.aggregates[key] = aggregate
        }
        save()
    }

    func removeAggregate(for url: URL) {
        let key = Self.key(for: url)
        lock.withLock { state in
            state.payload.aggregates[key] = nil
        }
        save()
    }

    func save() {
        let needsTask = lock.withLock { state -> Bool in
            state.dirty = true
            return state.saveTask == nil
        }
        if needsTask {
            scheduleSave()
        }
    }

    func flush() {
        let pending = lock.withLock { state -> (Task<Void, Never>?, FilePayload?) in
            let task = state.saveTask
            state.saveTask = nil
            guard state.dirty else { return (task, nil) }
            state.dirty = false
            return (task, state.payload)
        }
        pending.0?.cancel()
        guard let payload = pending.1 else { return }
        write(payload)
    }

    private func scheduleSave() {
        let task = Task { [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushFromScheduledTask()
        }

        let shouldCancel = lock.withLock { state -> Bool in
            if state.saveTask == nil {
                state.saveTask = task
                return false
            } else {
                return true
            }
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func flushFromScheduledTask() {
        let payload = lock.withLock { state -> FilePayload? in
            state.saveTask = nil
            guard state.dirty else { return nil }
            state.dirty = false
            return state.payload
        }
        guard let payload else { return }
        write(payload)
    }

    private func write(_ payload: FilePayload) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            markDirtyAfterFailedWrite()
        }
    }

    private func markDirtyAfterFailedWrite() {
        let needsTask = lock.withLock { state -> Bool in
            state.dirty = true
            return state.saveTask == nil
        }
        if needsTask {
            scheduleSave()
        }
    }

    private static func loadPayload(from fileURL: URL) -> FilePayload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(FilePayload.self, from: data),
              payload.schemaVersion == 1 else {
            return FilePayload()
        }
        return payload
    }

    private static func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultApplicationSupportDirectory() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "Taijia.LiveWallpaper"
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
    }
}
