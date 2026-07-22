import CryptoKit
import Foundation
import os

struct TailCursorState: Codable, Sendable, Equatable {
    var inode: UInt64
    var size: UInt64
    var offset: UInt64
}

struct SessionAggregateState: Codable, Sendable, Equatable {
    /// The persistence format is count-bounded rather than byte-bounded.
    static let maximumPersistedMetadataUTF8Bytes = 128

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
    fileprivate var requiresPersistenceNormalization = false

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
        let decodedToolName = try container.decodeIfPresent(String.self, forKey: .lastToolName)
        self.lastToolName = Self.boundedPersistedString(decodedToolName)
        self.pendingToolUse = try container.decodeIfPresent(Bool.self, forKey: .pendingToolUse)
        let decodedStopReason = try container.decodeIfPresent(String.self, forKey: .lastAssistantStopReason)
        self.lastAssistantStopReason = Self.boundedPersistedString(decodedStopReason)
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
        self.requiresPersistenceNormalization = decodedToolName != lastToolName
            || decodedStopReason != lastAssistantStopReason
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(turnCount, forKey: .turnCount)
        try container.encode(tokens, forKey: .tokens)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(lastEventAt, forKey: .lastEventAt)
        try container.encodeIfPresent(Self.boundedPersistedString(lastToolName), forKey: .lastToolName)
        try container.encodeIfPresent(pendingToolUse, forKey: .pendingToolUse)
        try container.encodeIfPresent(
            Self.boundedPersistedString(lastAssistantStopReason),
            forKey: .lastAssistantStopReason
        )
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

    /// Identity fields are intentionally memory-only, so they must not trigger
    /// a disk rewrite when the resume state encoded by `CodingKeys` is unchanged.
    fileprivate func hasSamePersistedState(as other: Self) -> Bool {
        provider == other.provider
            && turnCount == other.turnCount
            && tokens == other.tokens
            && startedAt == other.startedAt
            && lastEventAt == other.lastEventAt
            && Self.boundedPersistedString(lastToolName) == Self.boundedPersistedString(other.lastToolName)
            && pendingToolUse == other.pendingToolUse
            && Self.boundedPersistedString(lastAssistantStopReason)
                == Self.boundedPersistedString(other.lastAssistantStopReason)
            && sawPermissionRequest == other.sawPermissionRequest
            && lastInboundAwaitsModel == other.lastInboundAwaitsModel
            && pendingApprovalAt == other.pendingApprovalAt
            && lastApprovalClearAt == other.lastApprovalClearAt
            && lastStatusEventAt == other.lastStatusEventAt
            && lastTerminalEventIsTaskComplete == other.lastTerminalEventIsTaskComplete
    }

    /// Keep the process-local cache under the same metadata bound as the JSON representation.
    fileprivate func normalizedForPersistence() -> Self {
        var copy = self
        copy.lastToolName = Self.boundedPersistedString(lastToolName)
        copy.lastAssistantStopReason = Self.boundedPersistedString(lastAssistantStopReason)
        copy.requiresPersistenceNormalization = false
        return copy
    }

    private static func boundedPersistedString(_ value: String?) -> String? {
        guard let value,
              value.utf8.count > maximumPersistedMetadataUTF8Bytes else {
            return value
        }

        var result = ""
        var byteCount = 0
        for scalar in value.unicodeScalars {
            let scalarByteCount = String(scalar).utf8.count
            guard byteCount + scalarByteCount <= maximumPersistedMetadataUTF8Bytes else { break }
            result.unicodeScalars.append(scalar)
            byteCount += scalarByteCount
        }
        return result
    }
}

final class MonitorTailCursorStore: Sendable {
    private static let currentSchemaVersion = 2
    /// The durable size contract is an entry-count bound.
    static let defaultMaxEntryCount = 2_048
    private static let defaultRetentionAge: TimeInterval = 90 * 24 * 60 * 60
    private static let defaultTouchPersistInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let defaultRetentionSweepInterval: TimeInterval = 6 * 60 * 60

    private struct FilePayload: Codable, Sendable, Equatable {
        var schemaVersion: Int
        var cursors: [String: TailCursorState]
        var aggregates: [String: SessionAggregateState]
        /// Last durable use of each path hash.
        var lastAccessedAt: [String: Double]

        init(
            schemaVersion: Int = MonitorTailCursorStore.currentSchemaVersion,
            cursors: [String: TailCursorState] = [:],
            aggregates: [String: SessionAggregateState] = [:],
            lastAccessedAt: [String: Double] = [:]
        ) {
            self.schemaVersion = schemaVersion
            self.cursors = cursors
            self.aggregates = aggregates
            self.lastAccessedAt = lastAccessedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            self.cursors = try container.decodeIfPresent([String: TailCursorState].self, forKey: .cursors) ?? [:]
            self.aggregates = try container.decodeIfPresent([String: SessionAggregateState].self, forKey: .aggregates) ?? [:]
            self.lastAccessedAt = try container.decodeIfPresent(
                [String: Double].self,
                forKey: .lastAccessedAt
            ) ?? [:]
        }
    }

    private struct LoadedPayload: Sendable {
        var payload: FilePayload
        var requiresRewrite: Bool
        var permitsWrites: Bool
    }

    private struct SchemaHeader: Decodable {
        var schemaVersion: Int

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }

    private struct State: Sendable {
        var payload: FilePayload
        /// Exact process-local LRU signal.
        var recentAccessedAt: [String: Double]
        var liveKeys: Set<String>
        var nextRetentionSweepAt: Double
        var permitsWrites: Bool
        var dirty = false
        var revision: UInt64 = 0
        var nextScheduledSaveID: UInt64 = 0
        var scheduledSaveID: UInt64?
        var saveTask: Task<Void, Never>?

        init(
            payload: FilePayload,
            now: Double,
            retentionSweepInterval: TimeInterval,
            permitsWrites: Bool
        ) {
            self.payload = payload
            self.recentAccessedAt = payload.lastAccessedAt
            self.liveKeys = Set(payload.cursors.keys).union(payload.aggregates.keys)
            self.nextRetentionSweepAt = now + retentionSweepInterval
            self.permitsWrites = permitsWrites
        }
    }

    private struct WriterState: Sendable {
        var lastCommittedRevision: UInt64 = 0
    }

    private let fileURL: URL
    private let debounceNanoseconds: UInt64
    private let maxEntryCount: Int
    private let retentionAge: TimeInterval
    private let touchPersistInterval: TimeInterval
    private let retentionSweepInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let lock: OSAllocatedUnfairLock<State>
    private let writerLock = OSAllocatedUnfairLock(initialState: WriterState())
    private let writeWillBegin: (@Sendable (UInt64) -> Void)?
    private let scheduledSaveWillFlush: (@Sendable (UInt64) -> Void)?
    private let scheduledSaveDidClaim: (@Sendable (UInt64) -> Void)?
    private let retentionSweepWillRun: (@Sendable () -> Void)?

    init(
        directory: URL? = nil,
        debounceInterval: TimeInterval = 5,
        maxEntryCount: Int = MonitorTailCursorStore.defaultMaxEntryCount,
        retentionAge: TimeInterval = MonitorTailCursorStore.defaultRetentionAge,
        touchPersistInterval: TimeInterval = MonitorTailCursorStore.defaultTouchPersistInterval,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        writeWillBegin: (@Sendable (UInt64) -> Void)? = nil,
        scheduledSaveWillFlush: (@Sendable (UInt64) -> Void)? = nil,
        scheduledSaveDidClaim: (@Sendable (UInt64) -> Void)? = nil,
        retentionSweepWillRun: (@Sendable () -> Void)? = nil
    ) {
        let root = directory ?? Self.defaultApplicationSupportDirectory()
        self.fileURL = root.appendingPathComponent("MonitorTailCursors.json", isDirectory: false)
        self.debounceNanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
        self.maxEntryCount = max(1, maxEntryCount)
        self.retentionAge = max(0, retentionAge)
        self.touchPersistInterval = min(max(0, touchPersistInterval), self.retentionAge)
        self.retentionSweepInterval = min(Self.defaultRetentionSweepInterval, self.retentionAge)
        self.now = now
        self.writeWillBegin = writeWillBegin
        self.scheduledSaveWillFlush = scheduledSaveWillFlush
        self.scheduledSaveDidClaim = scheduledSaveDidClaim
        self.retentionSweepWillRun = retentionSweepWillRun
        let loadTime = now()
        let loaded = Self.loadPayload(
            from: fileURL,
            maxEntryCount: self.maxEntryCount,
            retentionAge: self.retentionAge,
            now: loadTime
        )
        self.lock = OSAllocatedUnfairLock(
            initialState: State(
                payload: loaded.payload,
                now: loadTime,
                retentionSweepInterval: self.retentionSweepInterval,
                permitsWrites: loaded.permitsWrites
            )
        )

        if loaded.requiresRewrite, loaded.permitsWrites {
            let scheduledSaveID = lock.withLock { state in
                markDirtyLocked(&state)
            }
            if let scheduledSaveID {
                scheduleSave(id: scheduledSaveID)
            }
        }
    }

    func state(for url: URL) -> TailCursorState? {
        let key = Self.key(for: url)
        let value: TailCursorState? = lock.withLock { state in
            state.payload.cursors[key]
        }
        if value != nil { touch(key: key) }
        return value
    }

    func set(_ cursorState: TailCursorState, for url: URL) {
        let key = Self.key(for: url)
        updatePayload(for: key, recordsAccess: true) { payload in
            guard payload.cursors[key] != cursorState else { return false }
            payload.cursors[key] = cursorState
            return true
        }
    }

    /// Commits the byte cursor and the model state derived through that cursor as one persistence generation.
    func set(_ cursorState: TailCursorState, aggregate: SessionAggregateState, for url: URL) {
        let key = Self.key(for: url)
        let normalizedAggregate = aggregate.normalizedForPersistence()
        updatePayload(for: key, recordsAccess: true) { payload in
            let cursorChanged = payload.cursors[key] != cursorState
            let aggregateChanged = payload.aggregates[key]?.hasSamePersistedState(as: normalizedAggregate) != true
            payload.cursors[key] = cursorState
            payload.aggregates[key] = normalizedAggregate
            return cursorChanged || aggregateChanged
        }
    }

    func remove(for url: URL) {
        let key = Self.key(for: url)
        updatePayload(for: key, recordsAccess: false) { payload in
            let removedCursor = payload.cursors.removeValue(forKey: key) != nil
            let removedAggregate = payload.aggregates.removeValue(forKey: key) != nil
            return removedCursor || removedAggregate
        }
    }

    func aggregate(for url: URL, provider: MonitorAgentProvider) -> SessionAggregateState? {
        let key = Self.key(for: url)
        let value: SessionAggregateState? = lock.withLock { state in
            guard let aggregate = state.payload.aggregates[key],
                  aggregate.provider == provider else {
                return nil
            }
            return aggregate
        }
        if value != nil { touch(key: key) }
        return value
    }

    func setAggregate(_ aggregate: SessionAggregateState, for url: URL) {
        let key = Self.key(for: url)
        let normalizedAggregate = aggregate.normalizedForPersistence()
        updatePayload(for: key, recordsAccess: true) { payload in
            let previous = payload.aggregates[key]
            payload.aggregates[key] = normalizedAggregate
            return previous?.hasSamePersistedState(as: normalizedAggregate) != true
        }
    }

    func removeAggregate(for url: URL) {
        let key = Self.key(for: url)
        updatePayload(for: key, recordsAccess: false) { payload in
            payload.aggregates.removeValue(forKey: key) != nil
        }
    }

    private func updatePayload(
        for key: String,
        recordsAccess: Bool,
        _ update: @Sendable (inout FilePayload) -> Bool
    ) {
        let timestamp = now()
        let result = lock.withLock { state -> (scheduledSaveID: UInt64?, ranSweep: Bool) in
            guard state.permitsWrites else { return (nil, false) }

            let payloadChanged = update(&state.payload)
            let isLive = state.payload.cursors[key] != nil || state.payload.aggregates[key] != nil
            if isLive {
                state.liveKeys.insert(key)
            } else {
                state.liveKeys.remove(key)
            }

            var durableTouchChanged = false
            if recordsAccess, isLive {
                state.recentAccessedAt[key] = timestamp
                let previous = state.payload.lastAccessedAt[key]
                if payloadChanged
                    || previous == nil
                    || timestamp - (previous ?? 0) >= touchPersistInterval {
                    if previous != timestamp {
                        state.payload.lastAccessedAt[key] = timestamp
                        durableTouchChanged = true
                    }
                }
            } else if !isLive {
                state.recentAccessedAt.removeValue(forKey: key)
                durableTouchChanged = state.payload.lastAccessedAt.removeValue(forKey: key) != nil
            }

            let countExceeded = state.liveKeys.count > maxEntryCount
            let sweepDue = timestamp >= state.nextRetentionSweepAt
            var retentionChanged = false
            if countExceeded || sweepDue {
                retentionChanged = Self.enforceRetention(
                    in: &state.payload,
                    recentAccessedAt: &state.recentAccessedAt,
                    liveKeys: &state.liveKeys,
                    maxEntryCount: maxEntryCount,
                    retentionAge: retentionAge,
                    now: timestamp,
                    protectedKey: recordsAccess && isLive ? key : nil
                )
                if sweepDue {
                    state.nextRetentionSweepAt = timestamp + retentionSweepInterval
                }
            }

            guard payloadChanged || durableTouchChanged || retentionChanged else {
                return (nil, countExceeded || sweepDue)
            }
            return (markDirtyLocked(&state), countExceeded || sweepDue)
        }
        if result.ranSweep {
            retentionSweepWillRun?()
        }
        if let scheduledSaveID = result.scheduledSaveID {
            scheduleSave(id: scheduledSaveID)
        }
    }

    private func touch(key: String) {
        updatePayload(for: key, recordsAccess: true) { _ in false }
    }

    private func markDirtyLocked(_ state: inout State) -> UInt64? {
        guard state.permitsWrites else { return nil }
        state.dirty = true
        state.revision &+= 1
        guard state.scheduledSaveID == nil else { return nil }
        state.nextScheduledSaveID &+= 1
        state.scheduledSaveID = state.nextScheduledSaveID
        return state.scheduledSaveID
    }

    func flush() {
        let pending = lock.withLock { state -> (Task<Void, Never>?, FilePayload?, UInt64) in
            guard state.permitsWrites else { return (nil, nil, state.revision) }
            let task = state.saveTask
            state.scheduledSaveID = nil
            state.saveTask = nil
            // A scheduled task may already have claimed this revision and cleared `dirty` without reaching the writer yet.
            guard state.dirty || state.revision > 0 else { return (task, nil, state.revision) }
            state.dirty = false
            return (task, state.payload, state.revision)
        }
        pending.0?.cancel()
        guard let payload = pending.1 else { return }
        write(payload, revision: pending.2)
    }

    private func scheduleSave(id: UInt64) {
        let task = Task { [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.scheduledSaveWillFlush?(id)
            self?.flushFromScheduledTask(id: id)
        }

        let shouldCancel = lock.withLock { state -> Bool in
            guard state.scheduledSaveID == id else { return true }
            state.saveTask = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func flushFromScheduledTask(id: UInt64) {
        let pending = lock.withLock { state -> (FilePayload, UInt64)? in
            guard state.scheduledSaveID == id else { return nil }
            state.scheduledSaveID = nil
            state.saveTask = nil
            guard state.dirty else { return nil }
            state.dirty = false
            return (state.payload, state.revision)
        }
        guard let pending else { return }
        scheduledSaveDidClaim?(id)
        write(pending.0, revision: pending.1)
    }

    private func write(_ payload: FilePayload, revision: UInt64) {
        writeWillBegin?(revision)
        let failed = writerLock.withLock { writer -> Bool in
            // Flush callers may arrive out of order.
            guard revision > writer.lastCommittedRevision else { return false }
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(payload)
                try data.write(to: fileURL, options: .atomic)
                writer.lastCommittedRevision = revision
                return false
            } catch {
                return true
            }
        }
        if failed {
            markDirtyAfterFailedWrite()
        }
    }

    private func markDirtyAfterFailedWrite() {
        let lastCommittedRevision = writerLock.withLock { writer in
            writer.lastCommittedRevision
        }
        let scheduledSaveID = lock.withLock { state -> UInt64? in
            guard state.revision > lastCommittedRevision else { return nil }
            state.dirty = true
            guard state.scheduledSaveID == nil else { return nil }
            state.nextScheduledSaveID &+= 1
            state.scheduledSaveID = state.nextScheduledSaveID
            return state.scheduledSaveID
        }
        if let scheduledSaveID {
            scheduleSave(id: scheduledSaveID)
        }
    }

    private static func loadPayload(
        from fileURL: URL,
        maxEntryCount: Int,
        retentionAge: TimeInterval,
        now: TimeInterval
    ) -> LoadedPayload {
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadedPayload(payload: FilePayload(), requiresRewrite: false, permitsWrites: true)
        }

        let decoder = JSONDecoder()
        if let header = try? decoder.decode(SchemaHeader.self, from: data),
           header.schemaVersion != 1,
           header.schemaVersion != currentSchemaVersion {
            return LoadedPayload(payload: FilePayload(), requiresRewrite: false, permitsWrites: false)
        }

        guard var payload = try? decoder.decode(FilePayload.self, from: data),
              payload.schemaVersion == 1 || payload.schemaVersion == currentSchemaVersion else {
            return LoadedPayload(payload: FilePayload(), requiresRewrite: false, permitsWrites: true)
        }

        let requiresMetadataRewrite = payload.aggregates.values.contains {
            $0.requiresPersistenceNormalization
        }
        if requiresMetadataRewrite {
            for key in Array(payload.aggregates.keys) {
                payload.aggregates[key]?.requiresPersistenceNormalization = false
            }
        }
        let original = payload
        payload.schemaVersion = currentSchemaVersion
        let fallbackAccess = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?
            .timeIntervalSince1970 ?? now
        let liveKeys = Set(payload.cursors.keys).union(payload.aggregates.keys)
        for key in liveKeys where payload.lastAccessedAt[key] == nil {
            payload.lastAccessedAt[key] = payload.aggregates[key]?.lastEventAt ?? fallbackAccess
        }
        var recentAccessedAt = payload.lastAccessedAt
        var retainedKeys = liveKeys
        _ = enforceRetention(
            in: &payload,
            recentAccessedAt: &recentAccessedAt,
            liveKeys: &retainedKeys,
            maxEntryCount: maxEntryCount,
            retentionAge: retentionAge,
            now: now,
            protectedKey: nil
        )
        return LoadedPayload(
            payload: payload,
            requiresRewrite: payload != original || requiresMetadataRewrite,
            permitsWrites: true
        )
    }

    /// Applies both age and count budgets to the union of cursor/aggregate keys.
    private static func enforceRetention(
        in payload: inout FilePayload,
        recentAccessedAt: inout [String: Double],
        liveKeys: inout Set<String>,
        maxEntryCount: Int,
        retentionAge: TimeInterval,
        now: TimeInterval,
        protectedKey: String?
    ) -> Bool {
        let originalCursorCount = payload.cursors.count
        let originalAggregateCount = payload.aggregates.count
        let originalRecency = payload.lastAccessedAt
        liveKeys = Set(payload.cursors.keys).union(payload.aggregates.keys)

        payload.lastAccessedAt = payload.lastAccessedAt.filter { liveKeys.contains($0.key) }
        recentAccessedAt = recentAccessedAt.filter { liveKeys.contains($0.key) }
        for key in liveKeys where payload.lastAccessedAt[key] == nil {
            let access = recentAccessedAt[key] ?? payload.aggregates[key]?.lastEventAt ?? now
            payload.lastAccessedAt[key] = access
            recentAccessedAt[key] = access
        }
        for key in liveKeys where recentAccessedAt[key] == nil {
            recentAccessedAt[key] = payload.lastAccessedAt[key] ?? now
        }

        let cutoff = now - retentionAge
        let staleKeys = liveKeys.filter { key in
            key != protectedKey && (recentAccessedAt[key] ?? now) < cutoff
        }
        remove(
            staleKeys,
            from: &payload,
            recentAccessedAt: &recentAccessedAt,
            liveKeys: &liveKeys
        )

        if liveKeys.count > maxEntryCount {
            let protected = protectedKey.map { Set([$0]) } ?? []
            let candidates = liveKeys.subtracting(protected)
            let overflow = liveKeys.count - maxEntryCount
            let olderFirst: (String, String) -> Bool = { lhs, rhs in
                let lhsAccess = recentAccessedAt[lhs] ?? 0
                let rhsAccess = recentAccessedAt[rhs] ?? 0
                return lhsAccess == rhsAccess ? lhs > rhs : lhsAccess < rhsAccess
            }
            let evicted: Set<String>
            if overflow == 1, let oldest = candidates.min(by: olderFirst) {
                evicted = [oldest]
            } else {
                evicted = Set(candidates.sorted(by: olderFirst).prefix(overflow))
            }
            remove(
                evicted,
                from: &payload,
                recentAccessedAt: &recentAccessedAt,
                liveKeys: &liveKeys
            )
        }

        return payload.cursors.count != originalCursorCount
            || payload.aggregates.count != originalAggregateCount
            || payload.lastAccessedAt != originalRecency
    }

    private static func remove(
        _ keys: Set<String>,
        from payload: inout FilePayload,
        recentAccessedAt: inout [String: Double],
        liveKeys: inout Set<String>
    ) {
        for key in keys {
            payload.cursors.removeValue(forKey: key)
            payload.aggregates.removeValue(forKey: key)
            payload.lastAccessedAt.removeValue(forKey: key)
            recentAccessedAt.removeValue(forKey: key)
            liveKeys.remove(key)
        }
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
