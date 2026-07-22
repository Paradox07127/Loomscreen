import Foundation
import Testing
import os
@testable import LiveWallpaper

@Suite("MonitorTailCursorStore")
struct MonitorTailCursorStoreTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonitorTailCursorStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func storageURL(in directory: URL) -> URL {
        directory.appendingPathComponent("MonitorTailCursors.json", isDirectory: false)
    }

    @Test("persists and loads cursor plus aggregate state from injected directory")
    func persistLoadRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let cursor = TailCursorState(inode: 42, size: 1024, offset: 512)
        let aggregate = makeAggregate()

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(cursor, aggregate: aggregate, for: transcript)
        store.flush()

        let loaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(loaded.state(for: transcript) == cursor)
        var expected = aggregate
        expected.sessionId = nil
        expected.projectName = nil
        expected.gitBranch = nil
        expected.model = nil
        #expect(loaded.aggregate(for: transcript, provider: .claude) == expected)
        #expect(loaded.aggregate(for: transcript, provider: .codex) == nil)
    }

    @Test("cursor and aggregate commit as one restorable generation")
    func cursorAndAggregateCommitTogether() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let cursor = TailCursorState(inode: 42, size: 2_048, offset: 1_024)
        let aggregate = makeAggregate(turnCount: 7)
        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)

        store.set(cursor, aggregate: aggregate, for: transcript)
        store.flush()

        let reloaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(reloaded.state(for: transcript) == cursor)
        #expect(reloaded.aggregate(for: transcript, provider: .claude)?.turnCount == 7)
    }

    @Test("Claude reload injects candidate identity and resumes JSONL after the durable cursor")
    func claudeReloadReconnectsIdentityAndCursor() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("claude-session.jsonl", isDirectory: false)
        let oldLine = Data(#"{"type":"old"}"#.utf8)
        var initialData = oldLine
        initialData.append(0x0A)
        try initialData.write(to: transcript, options: .atomic)

        let initialReader = JSONLTailReader(url: transcript)
        #expect(try initialReader.poll().newLines == [oldLine])
        let cursor = try #require(initialReader.cursorState)
        var aggregate = makeAggregate(turnCount: 7)
        aggregate.sessionId = "must-not-reach-disk"

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(cursor, aggregate: aggregate, for: transcript)
        store.flush()

        let reloaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        let storedCursor = try #require(reloaded.state(for: transcript))
        let storedAggregate = try #require(reloaded.aggregate(for: transcript, provider: .claude))
        #expect(storedAggregate.sessionId == nil)

        let newLine = Data(#"{"type":"new"}"#.utf8)
        var appendedData = newLine
        appendedData.append(0x0A)
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)

        let bootstrap = ClaudeAgentSource.makeTailBootstrap(
            url: transcript,
            candidateSessionID: "candidate-session-id",
            storedCursor: storedCursor,
            storedAggregate: storedAggregate
        )
        #expect(bootstrap.restoredModel?.sessionId == "candidate-session-id")
        let resumed = try bootstrap.reader.poll()
        #expect(!resumed.didRotate)
        #expect(resumed.newLines == [newLine])
    }

    @Test("agent sources persist cursor and aggregate through the atomic store API")
    func agentSourcesUseAtomicCursorAggregateCommit() throws {
        for relativePath in [
            "LiveWallpaper/Monitor/Sources/ClaudeAgentSource.swift",
            "LiveWallpaper/Monitor/Sources/CodexAgentSource.swift",
        ] {
            let source = try RepositoryRoot.source(relativePath)
            #expect(source.contains("set(cursorState, aggregate:"), "Missing atomic commit in \(relativePath)")
            #expect(!source.contains("setAggregate(model.snapshotState()"), "Split commit remains in \(relativePath)")
        }
    }

    @Test("debounced save flushes without explicit flush")
    func debouncedFlushWorks() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.codex/sessions/rollout-session.jsonl")
        let cursor = TailCursorState(inode: 7, size: 80, offset: 40)

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 0.05)
        store.set(cursor, for: transcript)
        try await Task.sleep(nanoseconds: 250_000_000)

        let loaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(loaded.state(for: transcript) == cursor)
    }

    @Test("stored JSON uses path hashes instead of raw transcript paths")
    func pathHashingOmitsRawPath() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/synthetic-secret/.claude/projects/private/session.jsonl")
        let cursor = TailCursorState(inode: 9, size: 128, offset: 128)

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(cursor, for: transcript)
        store.flush()

        let data = try Data(contentsOf: storageURL(in: dir))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("/Users"))
        #expect(!json.contains("synthetic-secret"))
        #expect(!json.contains("session.jsonl"))
    }

    @Test("ten thousand transcript paths compact to the configured entry-count budget")
    func tenThousandPathsStayBounded() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = OSAllocatedUnfairLock(initialState: 1_000_000.0)
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 128,
            retentionAge: .infinity,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )
        let oldest = URL(fileURLWithPath: "/synthetic/transcripts/0.jsonl")
        let newest = URL(fileURLWithPath: "/synthetic/transcripts/9999.jsonl")

        for index in 0..<10_000 {
            clock.withLock { $0 += 1 }
            var aggregate = makeAggregate(turnCount: index)
            aggregate.lastEventAt = clock.withLock { $0 }
            let url = URL(fileURLWithPath: "/synthetic/transcripts/\(index).jsonl")
            let cursor = TailCursorState(
                inode: UInt64(index + 1),
                size: UInt64(index + 10),
                offset: UInt64(index + 10)
            )
            store.set(cursor, aggregate: aggregate, for: url)
        }
        store.flush()

        let data = try Data(contentsOf: storageURL(in: dir))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cursors = try #require(root["cursors"] as? [String: Any])
        let aggregates = try #require(root["aggregates"] as? [String: Any])
        let recency = try #require(root["lastAccessedAt"] as? [String: Any])

        #expect(root["schemaVersion"] as? Int == 2)
        #expect(cursors.count == 128)
        #expect(aggregates.count == 128)
        #expect(recency.count == 128)
        #expect(store.state(for: oldest) == nil)
        #expect(store.state(for: newest)?.offset == 10_009)
    }

    @Test("the shipping default enforces its documented 2048-entry count bound")
    func productionDefaultEntryCountIsBounded() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            retentionAge: .infinity,
            touchPersistInterval: .infinity
        )
        let newest = URL(fileURLWithPath: "/synthetic/default-bound/latest.jsonl")

        for index in 0..<MonitorTailCursorStore.defaultMaxEntryCount {
            let url = URL(fileURLWithPath: "/synthetic/default-bound/\(index).jsonl")
            store.set(TailCursorState(inode: UInt64(index + 1), size: 1, offset: 1), for: url)
        }
        store.set(TailCursorState(inode: 9_999, size: 2, offset: 2), for: newest)
        store.flush()

        let data = try Data(contentsOf: storageURL(in: dir))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["cursors"] as? [String: Any])?.count == MonitorTailCursorStore.defaultMaxEntryCount)
        #expect((root["lastAccessedAt"] as? [String: Any])?.count == MonitorTailCursorStore.defaultMaxEntryCount)
        #expect(store.state(for: newest)?.offset == 2)
    }

    @Test("transcript-controlled persisted strings are UTF-8 byte bounded")
    func persistedMetadataStringsAreBounded() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/synthetic/metadata-bound/session.jsonl")
        let privateTail = "must-not-survive-the-persistence-bound"
        var aggregate = makeAggregate()
        aggregate.lastToolName = String(repeating: "tool", count: 100) + privateTail
        aggregate.lastAssistantStopReason = String(repeating: "🧪", count: 100) + privateTail

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(
            TailCursorState(inode: 1, size: 1, offset: 1),
            aggregate: aggregate,
            for: transcript
        )
        let cached = try #require(store.aggregate(for: transcript, provider: .claude))
        #expect((cached.lastToolName?.utf8.count ?? 0) <= SessionAggregateState.maximumPersistedMetadataUTF8Bytes)
        #expect(
            (cached.lastAssistantStopReason?.utf8.count ?? 0)
                <= SessionAggregateState.maximumPersistedMetadataUTF8Bytes
        )
        store.flush()

        let loaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        let persisted = try #require(loaded.aggregate(for: transcript, provider: .claude))
        #expect((persisted.lastToolName?.utf8.count ?? 0) <= SessionAggregateState.maximumPersistedMetadataUTF8Bytes)
        #expect(
            (persisted.lastAssistantStopReason?.utf8.count ?? 0)
                <= SessionAggregateState.maximumPersistedMetadataUTF8Bytes
        )
        let json = String(decoding: try Data(contentsOf: storageURL(in: dir)), as: UTF8.self)
        #expect(!json.contains(privateTail))

        let file = storageURL(in: dir)
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var aggregates = try #require(root["aggregates"] as? [String: Any])
        let key = try #require(aggregates.keys.first)
        var record = try #require(aggregates[key] as? [String: Any])
        record["lastAssistantStopReason"] = String(repeating: "x", count: 512) + privateTail
        aggregates[key] = record
        root["aggregates"] = aggregates
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            .write(to: file, options: .atomic)

        let normalizingLoad = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        normalizingLoad.flush()
        let normalizedJSON = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!normalizedJSON.contains(privateTail))
    }

    @Test("entries older than the retention window are removed on the next mutation and restart")
    func staleEntriesExpireAcrossRestart() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = OSAllocatedUnfairLock(initialState: 10_000.0)
        let oldURL = URL(fileURLWithPath: "/synthetic/old.jsonl")
        let currentURL = URL(fileURLWithPath: "/synthetic/current.jsonl")
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 16,
            retentionAge: 100,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )

        store.set(TailCursorState(inode: 1, size: 10, offset: 10), for: oldURL)
        store.flush()
        clock.withLock { $0 += 101 }
        store.set(TailCursorState(inode: 2, size: 20, offset: 20), for: currentURL)
        store.flush()

        #expect(store.state(for: oldURL) == nil)
        #expect(store.state(for: currentURL)?.offset == 20)

        let reloaded = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 16,
            retentionAge: 100,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )
        #expect(reloaded.state(for: oldURL) == nil)
        #expect(reloaded.state(for: currentURL)?.offset == 20)
    }

    @Test("a hot read refreshes in-memory LRU and its throttled durable touch")
    func readTouchSurvivesAnotherMutationAndRestart() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = OSAllocatedUnfairLock(initialState: 30_000.0)
        let hotURL = URL(fileURLWithPath: "/synthetic/hot.jsonl")
        let otherURL = URL(fileURLWithPath: "/synthetic/other.jsonl")
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 16,
            retentionAge: 100,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )

        store.set(TailCursorState(inode: 1, size: 10, offset: 10), for: hotURL)
        store.flush()
        clock.withLock { $0 += 101 }

        #expect(store.state(for: hotURL)?.offset == 10)
        store.set(TailCursorState(inode: 2, size: 20, offset: 20), for: otherURL)
        store.flush()

        let reloaded = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 16,
            retentionAge: 100,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )
        #expect(reloaded.state(for: hotURL)?.offset == 10)
        #expect(reloaded.state(for: otherURL)?.offset == 20)
    }

    @Test("expired entries are removed while loading without an intervening mutation")
    func loadAloneEnforcesRetention() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = OSAllocatedUnfairLock(initialState: 40_000.0)
        let oldURL = URL(fileURLWithPath: "/synthetic/load-expired.jsonl")
        let seed = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            retentionAge: .infinity,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )
        seed.set(TailCursorState(inode: 1, size: 10, offset: 10), for: oldURL)
        seed.flush()
        clock.withLock { $0 += 101 }

        let loaded = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            retentionAge: 100,
            now: { clock.withLock { $0 } }
        )
        #expect(loaded.state(for: oldURL) == nil)
        loaded.flush()

        let reloaded = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            retentionAge: 100,
            now: { clock.withLock { $0 } }
        )
        #expect(reloaded.state(for: oldURL) == nil)
    }

    @Test("schema one payload migrates by event recency and remains resumable")
    func legacySchemaMigratesAndRetainsNewestResumePairs() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = OSAllocatedUnfairLock(initialState: 20_000.0)
        let urls = (0..<3).map { URL(fileURLWithPath: "/synthetic/legacy/\($0).jsonl") }
        let seed = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 8,
            retentionAge: .infinity,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )
        for (index, url) in urls.enumerated() {
            var aggregate = makeAggregate(turnCount: index + 1)
            aggregate.lastEventAt = Double(100 + index)
            seed.set(
                TailCursorState(inode: UInt64(index + 1), size: 100, offset: UInt64(10 + index)),
                aggregate: aggregate,
                for: url
            )
        }
        seed.flush()

        let file = storageURL(in: dir)
        var legacy = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        legacy["schemaVersion"] = 1
        legacy.removeValue(forKey: "lastAccessedAt")
        try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)

        let migrated = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            maxEntryCount: 2,
            retentionAge: .infinity,
            touchPersistInterval: .infinity,
            now: { clock.withLock { $0 } }
        )
        migrated.flush()

        #expect(migrated.state(for: urls[0]) == nil)
        #expect(migrated.state(for: urls[1])?.offset == 11)
        #expect(migrated.aggregate(for: urls[1], provider: .claude)?.turnCount == 2)
        #expect(migrated.state(for: urls[2])?.offset == 12)
        #expect(migrated.aggregate(for: urls[2], provider: .claude)?.turnCount == 3)

        let rewritten = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        #expect(rewritten["schemaVersion"] as? Int == 2)
        #expect((rewritten["cursors"] as? [String: Any])?.count == 2)
        #expect((rewritten["lastAccessedAt"] as? [String: Any])?.count == 2)
    }

    @Test("an unknown future schema is preserved and makes the store read-only")
    func futureSchemaCannotBeOverwrittenByMutation() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = storageURL(in: dir)
        let futureData = Data(
            #"{"schemaVersion":3,"cursors":{"future-key":{"inode":1,"size":1,"offset":1}},"futureField":"preserve-me"}"#.utf8
        )
        try futureData.write(to: file, options: .atomic)
        let newURL = URL(fileURLWithPath: "/synthetic/must-not-overwrite.jsonl")

        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 0)
        store.set(TailCursorState(inode: 2, size: 2, offset: 2), for: newURL)
        store.flush()

        #expect(store.state(for: newURL) == nil)
        #expect(try Data(contentsOf: file) == futureData)
    }

    @Test("setting an unchanged cursor does not rewrite the persisted file")
    func unchangedCursorDoesNotRewriteFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let cursor = TailCursorState(inode: 42, size: 1024, offset: 512)
        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)

        store.set(cursor, for: transcript)
        store.flush()

        let file = storageURL(in: dir)
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        let sentinelReadBack = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        )

        store.set(cursor, for: transcript)
        store.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == sentinelReadBack)
    }

    @Test("no-op sets and touches stay on the O(1) path until maintenance is due")
    func noOpPollingDoesNotRunRetentionSweep() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/synthetic/no-op/session.jsonl")
        let cursor = TailCursorState(inode: 42, size: 1024, offset: 512)
        let clock = OSAllocatedUnfairLock(initialState: 50_000.0)
        let sweepCount = OSAllocatedUnfairLock(initialState: 0)
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            retentionAge: 10_000,
            touchPersistInterval: 1_000,
            now: { clock.withLock { $0 } },
            retentionSweepWillRun: { sweepCount.withLock { $0 += 1 } }
        )
        store.set(cursor, for: transcript)
        store.flush()

        for _ in 0..<10_000 {
            store.set(cursor, for: transcript)
            _ = store.state(for: transcript)
        }
        store.flush()

        #expect(store.state(for: transcript) == cursor)
        #expect(sweepCount.withLock { $0 } == 0)
    }

    @Test("equal aggregate is skipped but a persisted aggregate change is written")
    func aggregateWritesOnlyWhenPersistedStateChanges() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.codex/sessions/rollout-session.jsonl")
        let original = makeAggregate()
        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)

        store.setAggregate(original, for: transcript)
        store.flush()

        let file = storageURL(in: dir)
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        let sentinelReadBack = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        )

        var identityOnlyChange = original
        identityOnlyChange.projectName = "renamed-in-memory"
        store.setAggregate(identityOnlyChange, for: transcript)
        store.flush()
        var attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == sentinelReadBack)
        #expect(store.aggregate(for: transcript, provider: .claude)?.projectName == "renamed-in-memory")

        var changed = identityOnlyChange
        changed.turnCount += 1
        store.setAggregate(changed, for: transcript)
        store.flush()
        attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date != sentinel)

        let loaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(loaded.aggregate(for: transcript, provider: .claude)?.turnCount == changed.turnCount)
    }

    @Test("removing an absent path does not rewrite the store")
    func removingAbsentPathDoesNotRewriteFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let absent = URL(fileURLWithPath: "/Users/example/.claude/projects/other/missing.jsonl")
        let store = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        store.set(TailCursorState(inode: 1, size: 2, offset: 2), for: existing)
        store.flush()

        let file = storageURL(in: dir)
        let sentinel = Date(timeIntervalSince1970: 1_234_567)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        let sentinelReadBack = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        )

        store.remove(for: absent)
        store.removeAggregate(for: absent)
        store.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.modificationDate] as? Date == sentinelReadBack)
    }

    @Test("an older concurrent flush cannot overwrite a newer cursor snapshot")
    func staleConcurrentFlushCannotOverwriteNewerSnapshot() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let oldCursor = TailCursorState(inode: 1, size: 10, offset: 5)
        let newCursor = TailCursorState(inode: 1, size: 20, offset: 20)
        let oldWriteStarted = DispatchSemaphore(value: 0)
        let releaseOldWrite = DispatchSemaphore(value: 0)
        let oldFlushFinished = DispatchSemaphore(value: 0)
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 60,
            writeWillBegin: { revision in
                guard revision == 1 else { return }
                oldWriteStarted.signal()
                releaseOldWrite.wait()
            }
        )

        store.set(oldCursor, for: transcript)
        DispatchQueue.global().async {
            store.flush()
            oldFlushFinished.signal()
        }
        #expect(oldWriteStarted.wait(timeout: .now() + 2) == .success)

        store.set(newCursor, for: transcript)
        store.flush()
        releaseOldWrite.signal()
        #expect(oldFlushFinished.wait(timeout: .now() + 2) == .success)

        let reloaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(reloaded.state(for: transcript) == newCursor)
    }

    @Test("a cancelled old scheduled save cannot clear the replacement task")
    func oldScheduledSaveCannotClearReplacementTask() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let oldCursor = TailCursorState(inode: 1, size: 10, offset: 5)
        let newCursor = TailCursorState(inode: 1, size: 20, offset: 20)
        let oldTaskPassedCancellationCheck = DispatchSemaphore(value: 0)
        let releaseOldTask = DispatchSemaphore(value: 0)
        let claimedSaveIDs = OSAllocatedUnfairLock(initialState: [UInt64]())
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 0.02,
            scheduledSaveWillFlush: { id in
                guard id == 1 else { return }
                oldTaskPassedCancellationCheck.signal()
                releaseOldTask.wait()
            },
            scheduledSaveDidClaim: { id in
                claimedSaveIDs.withLock { $0.append(id) }
            }
        )

        store.set(oldCursor, for: transcript)
        #expect(oldTaskPassedCancellationCheck.wait(timeout: .now() + 2) == .success)

        store.flush()
        store.set(newCursor, for: transcript)
        releaseOldTask.signal()

        let deadline = Date().addingTimeInterval(2)
        var persisted: TailCursorState?
        repeat {
            persisted = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
                .state(for: transcript)
            if persisted == newCursor { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline

        #expect(persisted == newCursor)
        #expect(claimedSaveIDs.withLock { $0 } == [2])
    }

    @Test("explicit flush commits a revision already claimed by a scheduled task")
    func flushWaitsForClaimedScheduledRevision() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = URL(fileURLWithPath: "/Users/example/.claude/projects/project/session.jsonl")
        let cursor = TailCursorState(inode: 1, size: 20, offset: 20)
        let scheduledTaskClaimed = DispatchSemaphore(value: 0)
        let releaseScheduledTask = DispatchSemaphore(value: 0)
        let store = MonitorTailCursorStore(
            directory: dir,
            debounceInterval: 0.02,
            scheduledSaveDidClaim: { id in
                guard id == 1 else { return }
                scheduledTaskClaimed.signal()
                releaseScheduledTask.wait()
            }
        )
        defer { releaseScheduledTask.signal() }

        store.set(cursor, for: transcript)
        #expect(scheduledTaskClaimed.wait(timeout: .now() + 2) == .success)

        store.flush()
        let reloaded = MonitorTailCursorStore(directory: dir, debounceInterval: 60)
        #expect(reloaded.state(for: transcript) == cursor)
    }

    private func makeAggregate(turnCount: Int = 3) -> SessionAggregateState {
        SessionAggregateState(
            provider: .claude,
            sessionId: "session",
            projectName: "project",
            gitBranch: "main",
            model: "claude-sonnet-4-5",
            turnCount: turnCount,
            tokens: MonitorTokenTotals(input: 10, output: 20, cacheRead: 30, cacheWrite: 40),
            startedAt: 100,
            lastEventAt: 200,
            lastToolName: "Bash",
            pendingToolUse: true,
            lastAssistantStopReason: "tool_use",
            sawPermissionRequest: false,
            lastInboundAwaitsModel: false
        )
    }
}
