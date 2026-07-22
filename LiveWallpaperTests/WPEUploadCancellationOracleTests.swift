#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    @Suite("RR-14 upload cancellation oracle")
    struct WPEUploadCancellationOracleTests {
        @Test(
            "Cancelled waiter never starts, stale generation never publishes, and admission drains",
            .timeLimit(.minutes(1))
        )
        func cancelledWaiterDoesNotStartAndStaleGenerationDoesNotPublish() async throws {
            let recorder = RR14UploadEventRecorder()
            let waiterQueued = RR14AsyncOneShot()
            let queue = WPEMetalTextureUploadQueue(
                label: "test.livewallpaper.rr14.blocked-one-lane",
                maxConcurrentUploads: 1,
                didUpdateAdmission: { snapshot in
                    if snapshot.waitingCount == 1 {
                        waiterQueued.signal()
                    }
                }
            )

            let firstStarted = RR14AsyncOneShot()
            let firstBlocker = RR14SynchronousBlocker()
            defer { firstBlocker.release() }
            let firstGeneration = recorder.currentGeneration
            let first = Self.makeUploadTask(
                id: "old-started",
                generation: firstGeneration,
                queue: queue,
                recorder: recorder,
                started: firstStarted,
                blocker: firstBlocker
            )
            defer { first.cancel() }
            try await firstStarted.wait()

            let waiterGeneration = recorder.currentGeneration
            let waiter = Self.makeUploadTask(
                id: "old-cancelled",
                generation: waiterGeneration,
                queue: queue,
                recorder: recorder
            )
            defer { waiter.cancel() }
            try await waiterQueued.wait()
            recorder.noteCancellationRequested("old-cancelled")
            waiter.cancel()
            await waiter.value

            #expect(queue.admissionSnapshot == .init(grantedCount: 1, waitingCount: 0))

            recorder.advanceGeneration()
            firstBlocker.release()
            await first.value

            let replacementGeneration = recorder.currentGeneration
            let replacement = Self.makeUploadTask(
                id: "new",
                generation: replacementGeneration,
                queue: queue,
                recorder: recorder
            )
            await replacement.value

            let snapshot = recorder.snapshot()
            #expect(snapshot.cancellationRequests == ["old-cancelled"])

            #expect(snapshot.started == ["old-started", "new"])
            #expect(snapshot.synchronousFinished == ["old-started", "new"])

            #expect(snapshot.staleDrops == ["old-started"])
            #expect(snapshot.cancelledBeforeSynchronousWork == ["old-cancelled"])
            #expect(snapshot.cancelledAfterSynchronousWork.isEmpty)
            #expect(snapshot.published == ["new"])
            #expect(queue.admissionSnapshot == .init(grantedCount: 0, waitingCount: 0))
        }

        @Test(
            "Multiple cancelled waiters drain without delaying replacement work",
            .timeLimit(.minutes(1))
        )
        func multipleCancelledWaitersDrainBeforeReplacement() async throws {
            let recorder = RR14UploadEventRecorder()
            let allWaitersQueued = RR14AsyncOneShot()
            let queue = WPEMetalTextureUploadQueue(
                label: "test.livewallpaper.rr14.cancel-many",
                maxConcurrentUploads: 1,
                didUpdateAdmission: { snapshot in
                    if snapshot.waitingCount == 3 {
                        allWaitersQueued.signal()
                    }
                }
            )

            let holderStarted = RR14AsyncOneShot()
            let holderBlocker = RR14SynchronousBlocker()
            defer { holderBlocker.release() }
            let generation = recorder.currentGeneration
            let holder = Self.makeUploadTask(
                id: "holder",
                generation: generation,
                queue: queue,
                recorder: recorder,
                started: holderStarted,
                blocker: holderBlocker
            )
            defer { holder.cancel() }
            try await holderStarted.wait()

            let waiterIDs = ["cancel-a", "cancel-b", "cancel-c"]
            let waiters = waiterIDs.map { id in
                Self.makeUploadTask(
                    id: id,
                    generation: generation,
                    queue: queue,
                    recorder: recorder
                )
            }
            try await allWaitersQueued.wait()
            for (id, waiter) in zip(waiterIDs, waiters) {
                recorder.noteCancellationRequested(id)
                waiter.cancel()
            }
            for waiter in waiters {
                await waiter.value
            }

            var snapshot = recorder.snapshot()
            #expect(snapshot.started == ["holder"])
            #expect(snapshot.cancelledBeforeSynchronousWork.count == waiterIDs.count)
            #expect(Set(snapshot.cancelledBeforeSynchronousWork) == Set(waiterIDs))
            #expect(queue.admissionSnapshot == .init(grantedCount: 1, waitingCount: 0))

            holderBlocker.release()
            await holder.value
            let replacement = Self.makeUploadTask(
                id: "replacement",
                generation: generation,
                queue: queue,
                recorder: recorder
            )
            await replacement.value

            snapshot = recorder.snapshot()
            #expect(snapshot.started == ["holder", "replacement"])
            #expect(snapshot.synchronousFinished == ["holder", "replacement"])
            #expect(queue.admissionSnapshot == .init(grantedCount: 0, waitingCount: 0))
        }

        @Test(
            "Running upload may finish after cancellation but perform throws and never publishes",
            .timeLimit(.minutes(1))
        )
        func runningUploadCancellationDiscardsCompletedValue() async throws {
            let events = RR14StringRecorder()
            let started = RR14AsyncOneShot()
            let blocker = RR14SynchronousBlocker()
            defer { blocker.release() }
            let queue = WPEMetalTextureUploadQueue(
                label: "test.livewallpaper.rr14.cancel-running",
                maxConcurrentUploads: 1
            )

            let upload = Task {
                do {
                    _ = try await queue.perform {
                        events.append("started")
                        started.signal()
                        try blocker.waitUntilReleased()
                        events.append("finished")
                        return "value"
                    }
                    events.append("published")
                } catch is CancellationError {
                    events.append("cancelled")
                } catch {
                    Issue.record("Unexpected running-upload failure: \(error)")
                }
            }
            try await started.wait()
            upload.cancel()
            blocker.release()
            await upload.value

            #expect(events.values == ["started", "finished", "cancelled"])
            #expect(queue.admissionSnapshot == .init(grantedCount: 0, waitingCount: 0))
        }

        @Test(
            "Cancellation after permit grant but before executor start skips synchronous closure",
            .timeLimit(.minutes(1))
        )
        func cancellationBetweenPermitAndExecutionSkipsOperation() async throws {
            let events = RR14StringRecorder()
            let executor = RR14ControlledUploadExecutor()
            let queue = WPEMetalTextureUploadQueue(
                label: "test.livewallpaper.rr14.cancel-before-try-begin",
                maxConcurrentUploads: 1,
                executor: executor
            )

            let upload = Task {
                do {
                    try await queue.perform {
                        events.append("started")
                    }
                    events.append("returned")
                } catch is CancellationError {
                    events.append("cancelled")
                } catch {
                    Issue.record("Unexpected pre-execution cancellation failure: \(error)")
                }
            }
            try await executor.waitUntilEnqueued()
            #expect(queue.admissionSnapshot == .init(grantedCount: 1, waitingCount: 0))

            upload.cancel()
            #expect(executor.runNext())
            await upload.value

            #expect(events.values == ["cancelled"])
            #expect(executor.pendingCount == 0)
            #expect(queue.admissionSnapshot == .init(grantedCount: 0, waitingCount: 0))
        }

        @Test(
            "Production reload owner quiesces admission until a new generation is ready",
            .timeLimit(.minutes(1))
        )
        @MainActor
        func reloadTaskOwnerQuiescesAndGatesGenerationPublication() async throws {
            let owner = WPEStaticTextureReloadTaskOwner()
            let oldStarted = RR14AsyncOneShot()
            let releaseOld = RR14DeterministicGate()
            defer { releaseOld.signal() }
            let publications = RR14StringRecorder()

            owner.resume(generation: 1)
            let oldTicket = try #require(owner.submit(path: "shared", generation: 1) { ticket in
                oldStarted.signal()
                await releaseOld.wait()
                if owner.canPublish(ticket) {
                    publications.append("old")
                }
            })
            try await oldStarted.wait()
            try await releaseOld.waitUntilWaiting()
            #expect(owner.canPublish(oldTicket))

            let oldDrain = owner.quiesce()
            #expect(!owner.isAccepting)
            #expect(!owner.canPublish(oldTicket))
            #expect(owner.taskCount == 0)
            #expect(owner.submit(path: "during-drain", generation: 1) { _ in } == nil)
            #expect(releaseOld.waitingCount == 1)

            releaseOld.signal()
            await oldDrain.wait()
            #expect(publications.values.isEmpty)

            owner.resume(generation: 2)
            let newFinished = RR14AsyncOneShot()
            let newTicket = try #require(owner.submit(path: "shared", generation: 2) { ticket in
                if owner.canPublish(ticket) {
                    publications.append("new")
                }
                newFinished.signal()
            })
            #expect(owner.canPublish(newTicket))
            try await newFinished.wait()
            #expect(publications.values == ["new"])

            let finalDrain = owner.quiesce()
            await finalDrain.wait()
            #expect(owner.pendingPaths.isEmpty)
        }

        @Test(
            "Late cleanup completion cannot remove a same-path successor handle",
            .timeLimit(.minutes(1))
        )
        @MainActor
        func lateCompletionKeepsSamePathSuccessorOwned() async throws {
            let owner = WPEStaticTextureReloadTaskOwner()
            let oldStarted = RR14AsyncOneShot()
            let releaseOld = RR14DeterministicGate()
            let successorStarted = RR14AsyncOneShot()
            let releaseSuccessor = RR14DeterministicGate()
            defer {
                releaseOld.signal()
                releaseSuccessor.signal()
            }

            owner.resume(generation: 7)
            _ = try #require(owner.submit(path: "same-path", generation: 7) { _ in
                oldStarted.signal()
                await releaseOld.wait()
            })
            try await oldStarted.wait()
            try await releaseOld.waitUntilWaiting()

            let cleanupDrain = owner.quiesce()
            #expect(releaseOld.waitingCount == 1)
            owner.resume(generation: 8)
            let successorTicket = try #require(owner.submit(path: "same-path", generation: 8) { _ in
                successorStarted.signal()
                await releaseSuccessor.wait()
            })
            try await successorStarted.wait()

            releaseOld.signal()
            await cleanupDrain.wait()
            #expect(owner.pendingPaths == ["same-path"])
            #expect(owner.taskCount == 1)
            #expect(owner.canPublish(successorTicket))

            releaseSuccessor.signal()
            let finalDrain = owner.quiesce()
            await finalDrain.wait()
            #expect(owner.pendingPaths.isEmpty)
        }

        @Test(
            "Reload admission caps concurrent work at 2 and still drains every submission",
            .timeLimit(.minutes(1))
        )
        @MainActor
        func reloadAdmissionCapsConcurrencyAndDrainsAllSubmissions() async throws {
            let owner = WPEStaticTextureReloadTaskOwner()
            let started = RR14StringRecorder()
            let secondSlotStarted = RR14AsyncOneShot()
            let release = RR14DeterministicGate()
            defer { release.signal() }

            owner.resume(generation: 1)
            let paths = (0 ..< 5).map { "reload-\($0)" }
            for path in paths {
                let ticket = owner.submit(path: path, generation: 1) { _ in
                    started.append(path)
                    if started.values.count == 2 {
                        secondSlotStarted.signal()
                    }
                    await release.wait()
                }
                #expect(ticket != nil)
            }
            #expect(owner.taskCount == paths.count)

            #expect(owner.submit(path: paths[0], generation: 1) { _ in } == nil)
            #expect(owner.taskCount == paths.count)

            try await secondSlotStarted.wait()
            #expect(started.values.count == 2)
            #expect(owner.activeReloadCount == 2)

            release.signal()
            while owner.taskCount > 0 {
                await Task.yield()
            }

            #expect(Set(started.values) == Set(paths))
            #expect(owner.activeReloadCount == 0)

            let drain = owner.quiesce()
            await drain.wait()
            #expect(owner.pendingPaths.isEmpty)
        }

        private static func makeUploadTask(
            id: String,
            generation: Int,
            queue: WPEMetalTextureUploadQueue,
            recorder: RR14UploadEventRecorder,
            started: RR14AsyncOneShot? = nil,
            blocker: RR14SynchronousBlocker? = nil
        ) -> Task<Void, Never> {
            Task {
                do {
                    let value = try await queue.perform {
                        recorder.noteStarted(id)
                        started?.signal()
                        try blocker?.waitUntilReleased()
                        recorder.noteSynchronousFinished(id)
                        return id
                    }
                    if Task.isCancelled {
                        recorder.noteCancelledAfterSynchronousWork(value)
                        return
                    }
                    recorder.publishIfCurrent(value, capturedGeneration: generation)
                } catch is CancellationError {
                    recorder.noteCancelledBeforeSynchronousWork(id)
                } catch {
                    Issue.record("Unexpected upload-oracle failure: \(error)")
                }
            }
        }
    }

    private final class RR14UploadEventRecorder: @unchecked Sendable {
        struct Snapshot: Equatable, Sendable {
            let cancellationRequests: [String]
            let started: [String]
            let synchronousFinished: [String]
            let cancelledBeforeSynchronousWork: [String]
            let cancelledAfterSynchronousWork: [String]
            let staleDrops: [String]
            let published: [String]
        }

        private let lock = NSLock()
        private var generation = 1
        private var cancellationRequests: [String] = []
        private var started: [String] = []
        private var synchronousFinished: [String] = []
        private var cancelledBeforeSynchronousWork: [String] = []
        private var cancelledAfterSynchronousWork: [String] = []
        private var staleDrops: [String] = []
        private var published: [String] = []

        var currentGeneration: Int {
            withStateLock { generation }
        }

        func advanceGeneration() {
            withStateLock { generation &+= 1 }
        }

        func noteCancellationRequested(_ id: String) {
            withStateLock { cancellationRequests.append(id) }
        }

        func noteStarted(_ id: String) {
            withStateLock { started.append(id) }
        }

        func noteSynchronousFinished(_ id: String) {
            withStateLock { synchronousFinished.append(id) }
        }

        func noteCancelledBeforeSynchronousWork(_ id: String) {
            withStateLock { cancelledBeforeSynchronousWork.append(id) }
        }

        func noteCancelledAfterSynchronousWork(_ id: String) {
            withStateLock { cancelledAfterSynchronousWork.append(id) }
        }

        func publishIfCurrent(_ id: String, capturedGeneration: Int) {
            withStateLock {
                if generation == capturedGeneration {
                    published.append(id)
                } else {
                    staleDrops.append(id)
                }
            }
        }

        func snapshot() -> Snapshot {
            withStateLock {
                Snapshot(
                    cancellationRequests: cancellationRequests,
                    started: started,
                    synchronousFinished: synchronousFinished,
                    cancelledBeforeSynchronousWork: cancelledBeforeSynchronousWork,
                    cancelledAfterSynchronousWork: cancelledAfterSynchronousWork,
                    staleDrops: staleDrops,
                    published: published
                )
            }
        }

        private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    private final class RR14AsyncOneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignalled = false
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            stream = pair.stream
            continuation = pair.continuation
        }

        func wait() async throws {
            try Task.checkCancellation()
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
            try Task.checkCancellation()
        }

        func signal() {
            lock.lock()
            guard !isSignalled else {
                lock.unlock()
                return
            }
            isSignalled = true
            lock.unlock()
            continuation.yield()
            continuation.finish()
        }

        deinit { continuation.finish() }
    }

    private final class RR14SynchronousBlocker: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func waitUntilReleased() throws {
            guard semaphore.wait(timeout: .now() + 30) == .success else {
                throw RR14OracleError.blockerTimedOut
            }
        }

        func release() {
            semaphore.signal()
        }
    }

    private enum RR14OracleError: Error {
        case blockerTimedOut
    }

    private final class RR14ControlledUploadExecutor: WPEMetalTextureUploadExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private let enqueued = RR14AsyncOneShot()
        private var operations: [@Sendable () -> Void] = []

        var pendingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return operations.count
        }

        func execute(_ operation: @escaping @Sendable () -> Void) {
            lock.lock()
            operations.append(operation)
            lock.unlock()
            enqueued.signal()
        }

        func waitUntilEnqueued() async throws {
            try await enqueued.wait()
        }

        func runNext() -> Bool {
            let operation: (@Sendable () -> Void)?
            lock.lock()
            if operations.isEmpty {
                operation = nil
            } else {
                operation = operations.removeFirst()
            }
            lock.unlock()
            operation?()
            return operation != nil
        }
    }

    private final class RR14DeterministicGate: @unchecked Sendable {
        private let lock = NSLock()
        private let waiterRegistered = RR14AsyncOneShot()
        private var isSignalled = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        var waitingCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return waiters.count
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isSignalled {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                    waiterRegistered.signal()
                }
            }
        }

        func waitUntilWaiting() async throws {
            try await waiterRegistered.wait()
        }

        func signal() {
            let resumptions: [CheckedContinuation<Void, Never>]
            lock.lock()
            guard !isSignalled else {
                lock.unlock()
                return
            }
            isSignalled = true
            resumptions = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            resumptions.forEach { $0.resume() }
        }
    }

    private final class RR14StringRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: String) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }
#endif
