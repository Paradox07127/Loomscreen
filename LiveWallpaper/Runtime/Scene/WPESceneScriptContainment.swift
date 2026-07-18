#if !LITE_BUILD
    import Foundation

    /// Conservative containment choices for community-authored SceneScript.
    ///
    /// E2-B1 wires `maximumConcurrentEvaluations` through `processShared`.
    /// Runtime and host-bridge limits are extended in
    /// `WPESceneScriptResourceBudget.swift` so this governor stays focused.
    enum WPESceneScriptContainmentDefaults {
        /// Upper bound intended for evaluations concurrently executing in the app
        /// process. Callers hold a permit around work on the engine's own queue.
        static let maximumConcurrentEvaluations = 4

        /// Scene-wide construction ceiling across text, layer, and transform scripts.
        static let maximumScriptInstancesPerScene = 128

        static let frameCapacityRejectionPolicy: WPESceneScriptCapacityRejectionPolicy = .keepLastCompleted
        static let setupCapacityRejectionPolicy: WPESceneScriptCapacityRejectionPolicy = .failSceneClosed
    }

    enum WPESceneScriptCapacityRejectionPolicy: Sendable, Equatable {
        case keepLastCompleted
        case failSceneClosed
    }

    /// Distinguishes caller-deadline expiry from admission rejection. Only a
    /// timed-out job was actually submitted and may still own its JSC queue;
    /// capacity rejection means no closure was dispatched.
    enum WPESceneScriptBoundedExecutionResult<Output> {
        case completed(Output)
        case timedOut
        case capacityUnavailable
    }

    enum WPESceneScriptAdmissionPolicy {
        case failFast(traversalEpoch: WPESceneScriptTraversalEpoch?)
        case waitUntilDeadline
    }

    /// Explicit renderer-traversal identity. The renderer creates one token at
    /// the start of a frame and passes it to every frame-tick evaluator. A domain
    /// is stable per renderer; generation is process-unique and monotonic.
    struct WPESceneScriptTraversalEpoch: Sendable, Hashable {
        fileprivate let domainID: UInt64
        fileprivate let generation: UInt64

        private final class Generator: @unchecked Sendable {
            private let lock = NSLock()
            private var nextGeneration: UInt64 = 0

            func next(domainID: UInt64) -> WPESceneScriptTraversalEpoch {
                lock.lock()
                nextGeneration &+= 1
                let generation = nextGeneration
                lock.unlock()
                return WPESceneScriptTraversalEpoch(
                    domainID: domainID,
                    generation: generation
                )
            }
        }

        private static let generator = Generator()

        static func next(domainID: UInt64) -> WPESceneScriptTraversalEpoch {
            generator.next(domainID: domainID)
        }
    }

    /// Process-global-capable, bounded fair admission gate for SceneScript work.
    ///
    /// This type deliberately owns no execution queue: each JSC engine keeps its
    /// existing per-instance serial queue. A stable participant may reserve at
    /// most one FIFO position, preventing a hot engine from filling the queue.
    /// Frame work probes without waiting; its reservation makes a fixed renderer
    /// traversal yield to participants rejected in the prior pass. The renderer
    /// explicitly completes each traversal: reservations not renewed by their own
    /// domain are then removed. Other renderers never infer abandonment from their
    /// own frame cadence, and suspend/teardown cancels a domain directly.
    /// Setup/static/property work may wait fairly, but only until its caller-owned
    /// deadline. The queued JSC closure still owns and releases the granted permit.
    final class WPESceneScriptExecutionGovernor: @unchecked Sendable {
        static let processShared = WPESceneScriptExecutionGovernor(
            limit: WPESceneScriptContainmentDefaults.maximumConcurrentEvaluations
        )

        private enum WaitMode {
            case opportunistic(domainID: UInt64, lastPolledGeneration: UInt64)
            case blocking
        }

        private struct Waiter {
            let participantID: UInt64
            var mode: WaitMode
        }

        private struct State {
            var active = 0
            var nextParticipantID: UInt64 = 0
            var activeParticipantIDs: Set<UInt64> = []
            var traversalDomainByParticipantID: [UInt64: UInt64] = [:]
            var participantIDsByTraversalDomain: [UInt64: Set<UInt64>] = [:]
            var latestTraversalGenerationByDomain: [UInt64: UInt64] = [:]
            var completedTraversalGenerationByDomain: [UInt64: UInt64] = [:]
            var waiters: [Waiter] = []
            // Per-domain concurrent permits held by frame-tick (reserved) work.
            // Frame admission is scheduled max-min fair across domains off these
            // counts so a renderer with dozens of live scripts can't monopolize
            // the shared pool and starve a lightly-scripted display's ticks
            // (multi-display: heavy scene dragging a light scene to a few FPS).
            // Only the reserved path feeds these; unreserved/blocking grants stay
            // domain-agnostic and are counted solely in `active`.
            var activeReservedCountByDomain: [UInt64: Int] = [:]
            var reservedDomainByActiveParticipant: [UInt64: UInt64] = [:]
            #if DEBUG
                var peak = 0
                var permitsGranted = 0
            #endif
        }

        private let limit: Int
        private let maximumWaitingParticipants: Int
        private let condition = NSCondition()
        private var state = State()

        init(
            limit: Int,
            maximumWaitingParticipants: Int = 256
        ) {
            precondition(limit > 0, "SceneScript execution limit must be positive")
            precondition(maximumWaitingParticipants > 0, "SceneScript wait queue limit must be positive")
            self.limit = limit
            self.maximumWaitingParticipants = maximumWaitingParticipants
        }

        /// Creates the stable identity retained by one evaluator/engine.
        func makeParticipant() -> Participant {
            condition.lock()
            state.nextParticipantID &+= 1
            let participantID = state.nextParticipantID
            condition.unlock()
            return Participant(governor: self, id: participantID)
        }

        /// Frame-tick admission: never waits. The explicit epoch is shared by all
        /// evaluator probes in one renderer traversal.
        func tryAcquire(
            for participant: Participant,
            in traversalEpoch: WPESceneScriptTraversalEpoch
        ) -> Permit? {
            precondition(participant.governor === self, "SceneScript participant belongs to another governor")
            condition.lock()
            defer { condition.unlock() }
            let participantID = participant.id
            guard acceptPoll(in: traversalEpoch) else { return nil }
            bind(participantID: participantID, to: traversalEpoch.domainID)

            // Defensive: a participant already holding a permit keeps/renews its
            // reservation but can never double-acquire.
            if state.activeParticipantIDs.contains(participantID) {
                if let index = waiterIndex(for: participantID) {
                    refreshPoll(at: index, epoch: traversalEpoch)
                } else if state.waiters.count < maximumWaitingParticipants {
                    state.waiters.append(opportunisticWaiter(
                        participantID: participantID,
                        epoch: traversalEpoch
                    ))
                }
                return nil
            }

            // Register (or renew) this probe in the bounded waiter queue, then admit
            // it only when it wins a free permit under the cross-domain fair
            // schedule below. Unifying the "new probe" and "renewed reservation"
            // paths keeps admission ordering identical whatever the frame cadence.
            let index: Int
            if let existing = waiterIndex(for: participantID) {
                refreshPoll(at: existing, epoch: traversalEpoch)
                index = existing
            } else {
                guard state.waiters.count < maximumWaitingParticipants else { return nil }
                state.waiters.append(opportunisticWaiter(
                    participantID: participantID,
                    epoch: traversalEpoch
                ))
                index = state.waiters.count - 1
            }

            if availablePermitCount > 0,
               reservedFairRank(ofWaiterAt: index) < availablePermitCount {
                state.waiters.remove(at: index)
                return grantPermit(to: participantID, reservedDomain: traversalEpoch.domainID)
            }
            return nil
        }

        /// Closes one renderer traversal. Only reservations owned by this domain
        /// and not polled in this exact generation are removed. Older or repeated
        /// completions are inert, so delayed callbacks cannot roll liveness back.
        /// This scans only the bounded waiter queue (maximum 256), never every
        /// live SceneScript participant; the common empty-queue path is constant.
        func completeTraversal(_ traversalEpoch: WPESceneScriptTraversalEpoch) {
            condition.lock()
            defer { condition.unlock() }
            let domainID = traversalEpoch.domainID
            let generation = traversalEpoch.generation
            let latest = state.latestTraversalGenerationByDomain[domainID] ?? 0
            let completed = state.completedTraversalGenerationByDomain[domainID] ?? 0
            guard generation > completed, generation >= latest else { return }

            state.latestTraversalGenerationByDomain[domainID] = generation
            state.completedTraversalGenerationByDomain[domainID] = generation
            let previousCount = state.waiters.count
            state.waiters.removeAll { waiter in
                guard case let .opportunistic(waiterDomainID, lastPolledGeneration) = waiter.mode else {
                    return false
                }
                return waiterDomainID == domainID && lastPolledGeneration < generation
            }
            if state.waiters.count != previousCount {
                condition.broadcast()
            }
        }

        /// Renderer suspend and static/on-demand completion use this temporary
        /// lifecycle seam. Blocking deadline waiters remain untouched.
        func cancelReservations(domainID: UInt64) {
            condition.lock()
            let previousCount = state.waiters.count
            state.waiters.removeAll { waiter in
                guard case let .opportunistic(waiterDomainID, _) = waiter.mode else { return false }
                return waiterDomainID == domainID
            }
            if state.participantIDsByTraversalDomain[domainID]?.isEmpty != false {
                state.latestTraversalGenerationByDomain.removeValue(forKey: domainID)
                state.completedTraversalGenerationByDomain.removeValue(forKey: domainID)
            } else if let latest = state.latestTraversalGenerationByDomain[domainID] {
                state.completedTraversalGenerationByDomain[domainID] = max(
                    latest,
                    state.completedTraversalGenerationByDomain[domainID] ?? 0
                )
            }
            if state.waiters.count != previousCount {
                condition.broadcast()
            }
            condition.unlock()
        }

        /// Permanent renderer-domain teardown. Unlike temporary cancellation,
        /// this also drops generation state and unbinds only the target domain's
        /// indexed participants. Quarantined engines may outlive their renderer;
        /// a future legitimate probe can therefore bind them to a fresh domain.
        func forgetDomain(domainID: UInt64) {
            condition.lock()
            let previousCount = state.waiters.count
            state.waiters.removeAll { waiter in
                guard case let .opportunistic(waiterDomainID, _) = waiter.mode else { return false }
                return waiterDomainID == domainID
            }
            state.latestTraversalGenerationByDomain.removeValue(forKey: domainID)
            state.completedTraversalGenerationByDomain.removeValue(forKey: domainID)
            let participantIDs = state.participantIDsByTraversalDomain.removeValue(forKey: domainID) ?? []
            for participantID in participantIDs {
                state.traversalDomainByParticipantID.removeValue(forKey: participantID)
            }
            if state.waiters.count != previousCount {
                condition.broadcast()
            }
            condition.unlock()
        }

        /// Event/non-frame fail-fast admission. It neither creates nor challenges
        /// a frame reservation, so repeated cursor probes cannot affect tick FIFO
        /// fairness. Existing reservations retain priority over this work.
        func tryAcquireUnreserved(for participant: Participant) -> Permit? {
            precondition(participant.governor === self, "SceneScript participant belongs to another governor")
            condition.lock()
            defer { condition.unlock() }
            let participantID = participant.id
            guard !state.activeParticipantIDs.contains(participantID),
                  waiterIndex(for: participantID) == nil,
                  state.waiters.count < availablePermitCount else { return nil }
            return grantPermit(to: participantID)
        }

        /// Load/property admission: waits in the same bounded FIFO only until the
        /// supplied monotonic deadline. Nil means no JSC closure was dispatched.
        func acquire(
            for participant: Participant,
            until deadline: DispatchTime
        ) -> Permit? {
            precondition(participant.governor === self, "SceneScript participant belongs to another governor")
            condition.lock()
            defer { condition.unlock() }
            let participantID = participant.id

            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline.uptimeNanoseconds else {
                    removeWaiter(for: participantID)
                    condition.broadcast()
                    return nil
                }

                if !state.activeParticipantIDs.contains(participantID) {
                    if let index = waiterIndex(for: participantID) {
                        state.waiters[index].mode = .blocking
                        discardOpportunisticWaiters(before: participantID)
                        if let refreshedIndex = waiterIndex(for: participantID),
                           waiterCanAcquire(at: refreshedIndex) {
                            state.waiters.remove(at: refreshedIndex)
                            return grantPermit(to: participantID)
                        }
                    } else if state.waiters.count < availablePermitCount {
                        return grantPermit(to: participantID)
                    } else if state.waiters.count < maximumWaitingParticipants {
                        state.waiters.append(Waiter(participantID: participantID, mode: .blocking))
                        discardOpportunisticWaiters(before: participantID)
                        if let refreshedIndex = waiterIndex(for: participantID),
                           waiterCanAcquire(at: refreshedIndex) {
                            state.waiters.remove(at: refreshedIndex)
                            return grantPermit(to: participantID)
                        }
                    } else {
                        return nil
                    }
                } else if waiterIndex(for: participantID) == nil {
                    guard state.waiters.count < maximumWaitingParticipants else { return nil }
                    state.waiters.append(Waiter(participantID: participantID, mode: .blocking))
                }

                // Recheck the monotonic deadline in bounded slices so a wall-clock
                // adjustment cannot turn NSCondition's Date-based wait unbounded.
                let waitNanos = min(deadline.uptimeNanoseconds - now, 50_000_000)
                _ = condition.wait(until: Date(
                    timeIntervalSinceNow: Double(waitNanos) / 1_000_000_000
                ))
            }
        }

        private var availablePermitCount: Int {
            max(limit - state.active, 0)
        }

        private func waiterIndex(for participantID: UInt64) -> Int? {
            state.waiters.firstIndex { $0.participantID == participantID }
        }

        private func waiterCanAcquire(at index: Int) -> Bool {
            index < availablePermitCount
        }

        /// Number of waiters the fair schedule serves before the frame-tick waiter
        /// at `index`, so a permit is granted only when fewer than the free-permit
        /// count outrank it. Ordering (max-min fair across renderer domains):
        ///   1. a blocking (load/property) waiter always precedes frame ticks;
        ///   2. else the domain currently holding fewer reserved permits goes first;
        ///   3. ties break by each domain's own FIFO position (round-robin), so a
        ///      domain with many queued scripts can't jump a domain with few;
        ///   4. final ties break by global insertion order for determinism.
        /// This is what stops a heavy renderer's dozens of live scripts from
        /// evicting a light renderer's few ticks on the shared pool.
        private func reservedFairRank(ofWaiterAt index: Int) -> Int {
            guard case let .opportunistic(targetDomain, _) = state.waiters[index].mode else {
                return index
            }
            // One O(n) pass to assign each opportunistic waiter its per-domain FIFO
            // rank (array order == that domain's arrival order).
            var domainSeen: [UInt64: Int] = [:]
            var domainRank = [Int](repeating: 0, count: state.waiters.count)
            for i in state.waiters.indices {
                if case let .opportunistic(domain, _) = state.waiters[i].mode {
                    let seen = domainSeen[domain, default: 0]
                    domainRank[i] = seen
                    domainSeen[domain] = seen + 1
                }
            }
            let targetActive = state.activeReservedCountByDomain[targetDomain] ?? 0
            let targetDomainRank = domainRank[index]
            var rank = 0
            for i in state.waiters.indices where i != index {
                switch state.waiters[i].mode {
                case .blocking:
                    rank += 1
                case let .opportunistic(domain, _):
                    let active = state.activeReservedCountByDomain[domain] ?? 0
                    if active != targetActive {
                        if active < targetActive { rank += 1 }
                    } else if domainRank[i] != targetDomainRank {
                        if domainRank[i] < targetDomainRank { rank += 1 }
                    } else if i < index {
                        rank += 1
                    }
                }
            }
            return rank
        }

        private func bind(participantID: UInt64, to domainID: UInt64) {
            if let existing = state.traversalDomainByParticipantID[participantID] {
                precondition(existing == domainID, "SceneScript participant crossed renderer traversal domains")
            } else {
                state.traversalDomainByParticipantID[participantID] = domainID
                state.participantIDsByTraversalDomain[domainID, default: []].insert(participantID)
            }
        }

        /// Accepts repeated probes in the current open traversal, advances to a
        /// newer generation, and rejects every closed or out-of-order epoch.
        private func acceptPoll(in epoch: WPESceneScriptTraversalEpoch) -> Bool {
            let latest = state.latestTraversalGenerationByDomain[epoch.domainID] ?? 0
            let completed = state.completedTraversalGenerationByDomain[epoch.domainID] ?? 0
            guard epoch.generation > completed, epoch.generation >= latest else { return false }
            if epoch.generation > latest {
                state.latestTraversalGenerationByDomain[epoch.domainID] = epoch.generation
            }
            return true
        }

        private func opportunisticWaiter(
            participantID: UInt64,
            epoch: WPESceneScriptTraversalEpoch
        ) -> Waiter {
            Waiter(
                participantID: participantID,
                mode: .opportunistic(
                    domainID: epoch.domainID,
                    lastPolledGeneration: epoch.generation
                )
            )
        }

        private func refreshPoll(at index: Int, epoch: WPESceneScriptTraversalEpoch) {
            guard case let .opportunistic(domainID, lastPolledGeneration) = state.waiters[index].mode,
                  domainID == epoch.domainID,
                  epoch.generation > lastPolledGeneration else {
                return
            }
            state.waiters[index].mode = .opportunistic(
                domainID: domainID,
                lastPolledGeneration: epoch.generation
            )
        }

        private func grantPermit(
            to participantID: UInt64,
            reservedDomain: UInt64? = nil
        ) -> Permit {
            precondition(state.active < limit, "SceneScript permit limit exceeded")
            precondition(
                state.activeParticipantIDs.insert(participantID).inserted,
                "SceneScript participant acquired more than one permit"
            )
            state.active += 1
            if let reservedDomain {
                state.activeReservedCountByDomain[reservedDomain, default: 0] += 1
                state.reservedDomainByActiveParticipant[participantID] = reservedDomain
            }
            #if DEBUG
                state.peak = max(state.peak, state.active)
                state.permitsGranted += 1
            #endif
            return Permit(governor: self, participantID: participantID)
        }

        private func removeWaiter(for participantID: UInt64) {
            state.waiters.removeAll { $0.participantID == participantID }
        }

        /// Blocking work has an active waiter and a finite deadline; abandoned
        /// fail-fast reservations ahead of it are advisory and can retry next
        /// frame. Preserve FIFO order among all blocking participants.
        private func discardOpportunisticWaiters(before participantID: UInt64) {
            guard let participantIndex = waiterIndex(for: participantID), participantIndex > 0 else { return }
            let prefix = state.waiters[..<participantIndex]
            let blockingPrefix = prefix.filter { waiter in
                if case .blocking = waiter.mode {
                    return true
                }
                return false
            }
            state.waiters.replaceSubrange(..<participantIndex, with: blockingPrefix)
        }

        private func cancelParticipant(_ participantID: UInt64) {
            condition.lock()
            removeWaiter(for: participantID)
            if let domainID = state.traversalDomainByParticipantID.removeValue(forKey: participantID) {
                state.participantIDsByTraversalDomain[domainID]?.remove(participantID)
                if state.participantIDsByTraversalDomain[domainID]?.isEmpty == true {
                    state.participantIDsByTraversalDomain.removeValue(forKey: domainID)
                    state.latestTraversalGenerationByDomain.removeValue(forKey: domainID)
                    state.completedTraversalGenerationByDomain.removeValue(forKey: domainID)
                }
            }
            condition.broadcast()
            condition.unlock()
        }

        private func releasePermit(for participantID: UInt64) {
            condition.lock()
            precondition(state.active > 0, "SceneScript permit accounting underflow")
            precondition(
                state.activeParticipantIDs.remove(participantID) != nil,
                "SceneScript participant permit accounting underflow"
            )
            state.active -= 1
            if let domain = state.reservedDomainByActiveParticipant.removeValue(forKey: participantID) {
                if let count = state.activeReservedCountByDomain[domain], count > 1 {
                    state.activeReservedCountByDomain[domain] = count - 1
                } else {
                    state.activeReservedCountByDomain.removeValue(forKey: domain)
                }
            }
            condition.broadcast()
            condition.unlock()
        }

        /// Stable identity for one evaluator. Its deinit cancels any abandoned
        /// frame reservation so a removed scene node cannot block the FIFO.
        final class Participant: @unchecked Sendable {
            fileprivate let governor: WPESceneScriptExecutionGovernor
            fileprivate let id: UInt64

            fileprivate init(governor: WPESceneScriptExecutionGovernor, id: UInt64) {
                self.governor = governor
                self.id = id
            }

            deinit {
                governor.cancelParticipant(id)
            }
        }

        /// Reference-semantic token so copies share one idempotent release latch.
        /// `deinit` is a fail-safe; callers should still release explicitly in the
        /// engine queue closure's `defer` so capacity becomes available promptly.
        final class Permit: @unchecked Sendable {
            private let lock = NSLock()
            private var governor: WPESceneScriptExecutionGovernor?
            private let participantID: UInt64

            fileprivate init(governor: WPESceneScriptExecutionGovernor, participantID: UInt64) {
                self.governor = governor
                self.participantID = participantID
            }

            func release() {
                lock.lock()
                let owner = governor
                governor = nil
                lock.unlock()
                owner?.releasePermit(for: participantID)
            }

            deinit {
                release()
            }
        }

        #if DEBUG
            /// Diagnostic surface compiled only for debug/test builds.
            struct DebugSnapshot: Sendable, Equatable {
                let active: Int
                let peak: Int
                let permitsGranted: Int
                let waitingParticipants: Int
            }

            var debugSnapshot: DebugSnapshot {
                condition.lock()
                defer { condition.unlock() }
                return DebugSnapshot(
                    active: state.active,
                    peak: state.peak,
                    permitsGranted: state.permitsGranted,
                    waitingParticipants: state.waiters.count
                )
            }

            var debugTrackedTraversalDomainCount: Int {
                condition.lock()
                defer { condition.unlock() }
                return state.latestTraversalGenerationByDomain.count
            }

            var debugBoundTraversalParticipantCount: Int {
                condition.lock()
                defer { condition.unlock() }
                return state.traversalDomainByParticipantID.count
            }
        #endif
    }

    enum WPESceneScriptOperation: String, Sendable, CaseIterable {
        case setup
        case tick
        case event
        case userProperties
        case staticTransform
    }

    /// First failure that disables a scene's entire script subsystem.
    enum WPESceneScriptFailClosedReason: Sendable, Equatable {
        case executionTimedOut(operation: WPESceneScriptOperation)
        case capacityUnavailable(operation: WPESceneScriptOperation)
        case scriptInstanceLimitExceeded(limit: Int)
        case createdLayerLimitExceeded(limit: Int)
        case videoCommandLimitExceeded(limit: Int)
        case sharedStateLimitExceeded(limit: Int)
        case quarantineLimitReached(limit: Int)
    }

    /// Load-time count of the JS runtime instances the renderer would construct.
    /// Static transform resolution is one parser-local evaluator with its own
    /// context ceiling; these counts cover the per-object runtimes retained and
    /// ticked by the renderer after load.
    struct WPESceneScriptInstanceInventory: Sendable, Equatable {
        let text: Int
        let layer: Int
        let transform: Int

        init(text: Int, layer: Int, transform: Int) {
            precondition(text >= 0 && layer >= 0 && transform >= 0)
            self.text = text
            self.layer = layer
            self.transform = transform
        }

        var total: Int {
            let (textAndLayer, firstOverflow) = text.addingReportingOverflow(layer)
            let (total, secondOverflow) = textAndLayer.addingReportingOverflow(transform)
            return firstOverflow || secondOverflow ? .max : total
        }
    }

    /// Immutable identity and first-failure latch for one renderer load.
    /// Limit+1 rejects every constructor; retirement and any resource failure
    /// reject later construction and publication carrying this exact identity.
    final class WPESceneScriptInstanceLimitToken: @unchecked Sendable {
        let generation: Int

        private struct State {
            var preparedInventory: WPESceneScriptInstanceInventory?
            var failureReason: WPESceneScriptFailClosedReason?
            var isRetired = false
        }

        private let instanceLimit: Int
        private let resourceBudget: WPESceneScriptSceneResourceBudget
        let executionQuarantine: WPESceneScriptQuarantine
        private let lock = NSLock()
        private var state = State()

        init(
            generation: Int,
            instanceLimit: Int = WPESceneScriptContainmentDefaults.maximumScriptInstancesPerScene,
            resourceBudget: WPESceneScriptSceneResourceBudget = WPESceneScriptSceneResourceBudget(),
            executionQuarantine: WPESceneScriptQuarantine = .processShared
        ) {
            precondition(instanceLimit >= 0)
            self.generation = generation
            self.instanceLimit = instanceLimit
            self.resourceBudget = resourceBudget
            self.executionQuarantine = executionQuarantine
        }

        /// Must be called once, before any renderer-owned runtime is constructed.
        /// Repeated calls are inert and cannot replace the first inventory.
        @discardableResult
        func prepare(_ inventory: WPESceneScriptInstanceInventory) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !state.isRetired, state.preparedInventory == nil else { return false }
            state.preparedInventory = inventory
            guard inventory.total <= instanceLimit else {
                state.failureReason = .scriptInstanceLimitExceeded(limit: instanceLimit)
                return false
            }
            return true
        }

        var failureReason: WPESceneScriptFailClosedReason? {
            lock.lock()
            defer { lock.unlock() }
            return state.failureReason
        }

        var preparedInventory: WPESceneScriptInstanceInventory? {
            lock.lock()
            defer { lock.unlock() }
            return state.preparedInventory
        }

        var isRetired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.isRetired
        }

        func allows(_: WPESceneScriptOperation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !state.isRetired && state.failureReason == nil
        }

        func withConstructionPermission<Instance>(
            _ construct: () throws -> Instance
        ) rethrows -> Instance? {
            lock.lock()
            let permitted = !state.isRetired
                && state.failureReason == nil
                && state.preparedInventory != nil
            lock.unlock()
            guard permitted else { return nil }
            guard executionQuarantine.canConstructRuntime else {
                failClosed(.quarantineLimitReached(
                    limit: executionQuarantine.limit
                ))
                return nil
            }
            let instance = try construct()
            return acceptsCompletion() ? instance : nil
        }

        /// Queue-side publish gate. Kept separate from `allows` so tests and
        /// engines can state the late-completion contract directly.
        func acceptsCompletion() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !state.isRetired && state.failureReason == nil
        }

        /// Linearization point for renderer-side completion effects. The
        /// closure executes while this token's failure/retirement latch is
        /// locked, so `failClosed` and `retire` are ordered wholly before or
        /// after the commit. The closure must not re-enter this token or its
        /// owning load state; callers preserve the load-state -> token order.
        @discardableResult
        func withCompletionPermission(
            _ commit: () throws -> Void
        ) rethrows -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !state.isRetired, state.failureReason == nil else { return false }
            try commit()
            return true
        }

        @discardableResult
        func failClosed(_ reason: WPESceneScriptFailClosedReason) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !state.isRetired, state.failureReason == nil else { return false }
            state.failureReason = reason
            return true
        }

        func admitCreatedLayer() -> Bool {
            guard acceptsCompletion() else { return false }
            guard resourceBudget.admitCreatedLayer() == .accepted else {
                failClosed(.createdLayerLimitExceeded(
                    limit: WPESceneScriptContainmentDefaults.maximumCreatedLayersPerScene
                ))
                return false
            }
            return acceptsCompletion()
        }

        func admitNewSharedStateEntry() -> Bool {
            guard acceptsCompletion() else { return false }
            guard resourceBudget.admitNewSharedStateEntry() == .accepted else {
                failClosed(.sharedStateLimitExceeded(
                    limit: WPESceneScriptContainmentDefaults.maximumSharedStateEntries
                ))
                return false
            }
            return acceptsCompletion()
        }

        var resourceSnapshot: WPESceneScriptSceneResourceBudget.Snapshot {
            resourceBudget.snapshot
        }

        func retire() {
            lock.lock()
            state.isRetired = true
            lock.unlock()
        }
    }

    /// Thread-safe owner of the one current B2a load identity. Retiring an old
    /// token never clears a newer current token.
    final class WPESceneScriptLoadState: @unchecked Sendable {
        private let lock = NSLock()
        private var current: WPESceneScriptInstanceLimitToken?

        func begin(generation: Int) -> WPESceneScriptInstanceLimitToken {
            let token = WPESceneScriptInstanceLimitToken(generation: generation)
            lock.lock()
            let previous = current
            previous?.retire()
            current = token
            lock.unlock()
            return token
        }

        func isCurrent(_ token: WPESceneScriptInstanceLimitToken) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return current === token
                && current?.generation == token.generation
                && !token.isRetired
        }

        /// Authorizes a frame/property completion against the exact token that
        /// is current at this linearization point. The commit must not re-enter
        /// either load-state or token APIs while both locks are held.
        @discardableResult
        func withCurrentCompletionPermission(
            _ commit: () throws -> Void
        ) rethrows -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let token = current else { return false }
            return try token.withCompletionPermission(commit)
        }

        /// Load completion additionally carries its captured token so a stale
        /// load can never borrow permission from the replacement load.
        @discardableResult
        func withCompletionPermission(
            for token: WPESceneScriptInstanceLimitToken,
            _ commit: () throws -> Void
        ) rethrows -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard current === token,
                  current?.generation == token.generation else { return false }
            return try token.withCompletionPermission(commit)
        }

        func retire(_ token: WPESceneScriptInstanceLimitToken) {
            lock.lock()
            if current === token {
                current = nil
            }
            lock.unlock()
            token.retire()
        }

        func retireCurrent() {
            lock.lock()
            let token = current
            current = nil
            lock.unlock()
            token?.retire()
        }

        var currentFailureReason: WPESceneScriptFailClosedReason? {
            lock.lock()
            defer { lock.unlock() }
            return current?.failureReason
        }
    }

    /// Thread-safe, per-scene stable snapshot plus a first-failure latch.
    ///
    /// A renderer can use a value-type aggregate as `Snapshot`: until something
    /// completes, presentation uses the baked snapshot; afterward it uses the last
    /// completed snapshot. Once failed closed, all operations and late completions
    /// are rejected. This remains a B2b primitive, not B2a production wiring.
    final class WPESceneScriptFailClosedState<Snapshot: Sendable>: @unchecked Sendable {
        private struct State {
            var lastCompleted: Snapshot?
            var failureReason: WPESceneScriptFailClosedReason?
        }

        private let baked: Snapshot
        private let lock = NSLock()
        private var state = State()

        init(baked: Snapshot) {
            self.baked = baked
        }

        var presentedSnapshot: Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return state.lastCompleted ?? baked
        }

        var failureReason: WPESceneScriptFailClosedReason? {
            lock.lock()
            defer { lock.unlock() }
            return state.failureReason
        }

        func allows(_: WPESceneScriptOperation) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.failureReason == nil
        }

        /// Returns false when a failure already latched; late results never replace
        /// the last stable snapshot.
        @discardableResult
        func publishCompleted(_ snapshot: Snapshot) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.failureReason == nil else { return false }
            state.lastCompleted = snapshot
            return true
        }

        /// First failure wins so diagnostics remain deterministic.
        @discardableResult
        func failClosed(_ reason: WPESceneScriptFailClosedReason) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.failureReason == nil else { return false }
            state.failureReason = reason
            return true
        }
    }

    /// Latest-outcome exchange whose in-flight claim carries a generation token.
    /// Rejecting or publishing an old claim cannot clear a newer claim or overwrite
    /// its outcome.
    final class WPESceneScriptClaimedOutcomeSlot<Outcome: Sendable>: @unchecked Sendable {
        struct Claim: Sendable, Equatable {
            fileprivate let generation: UInt64
        }

        private struct State {
            var nextGeneration: UInt64 = 0
            var inFlightGeneration: UInt64?
            var latest: Outcome?
        }

        private let lock = NSLock()
        private var state = State()

        var isInFlight: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.inFlightGeneration != nil
        }

        func beginClaim() -> Claim? {
            lock.lock()
            defer { lock.unlock() }
            guard state.inFlightGeneration == nil else { return nil }
            state.nextGeneration &+= 1
            state.inFlightGeneration = state.nextGeneration
            return Claim(generation: state.nextGeneration)
        }

        /// Releases only the matching claim. Returns false for a stale generation.
        @discardableResult
        func reject(_ claim: Claim) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.inFlightGeneration == claim.generation else { return false }
            state.inFlightGeneration = nil
            return true
        }

        /// Publishes only for the currently active claim. A late old-generation
        /// completion is discarded without touching a newer in-flight claim.
        @discardableResult
        func publish(_ outcome: Outcome, for claim: Claim) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state.inFlightGeneration == claim.generation else { return false }
            state.inFlightGeneration = nil
            state.latest = outcome
            return true
        }

        func takeLatest() -> Outcome? {
            lock.lock()
            defer { lock.unlock() }
            defer { state.latest = nil }
            return state.latest
        }
    }
#endif
