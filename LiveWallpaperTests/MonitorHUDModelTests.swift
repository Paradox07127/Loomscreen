import Testing
@testable import LiveWallpaper

@Suite("Monitor HUD model")
struct MonitorHUDModelTests {

    // MARK: - Builders

    private func session(
        id: String,
        provider: MonitorAgentProvider = .claude,
        project: String = "proj",
        status: MonitorAgentStatus,
        detail: String? = nil,
        lastEventAt: Double = 1000,
        waitSince: Double? = nil,
        contextUsedPercent: Double? = nil,
        warning: String? = nil
    ) -> MonitorAgentSessionState {
        var state = MonitorAgentSessionState(
            id: id,
            provider: provider,
            projectName: project,
            status: status,
            statusDetail: detail,
            lastEventAt: lastEventAt,
            processAlive: true
        )
        state.waitSince = waitSince
        state.contextUsedPercent = contextUsedPercent
        state.warning = warning
        return state
    }

    private func snapshot(_ agents: [MonitorAgentSessionState]?) -> MonitorSnapshot {
        var snap = MonitorSnapshot()
        snap.agents = agents
        return snap
    }

    // MARK: - Empty / no-sessions

    @Test("nil snapshot yields the empty model")
    func nilSnapshotIsEmpty() {
        let model = MonitorHUDModel.make(from: nil, now: 1000, lastPublishAt: nil)
        #expect(model == .empty)
        #expect(model.presentation == .collapsed)
        #expect(model.aggregate == .noSessions)
        #expect(model.providerDots.isEmpty)
    }

    @Test("nil agents module yields the empty model")
    func nilAgentsIsEmpty() {
        let model = MonitorHUDModel.make(from: snapshot(nil), now: 1000, lastPublishAt: nil)
        #expect(model.aggregate == .noSessions)
        #expect(model.blocked == nil)
    }

    @Test("only ended sessions read as no active sessions, not a dot")
    func endedSessionsAreNotLive() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .ended)]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.aggregate == .noSessions)
        #expect(model.providerDots.isEmpty)
        #expect(model.presentation == .collapsed)
    }

    // MARK: - Aggregate selection

    @Test("needsInput dominates running in the aggregate")
    func needsInputDominates() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .running),
                session(id: "b", status: .needsInput),
                session(id: "c", status: .running)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.aggregate == .needsInput(1))
        #expect(model.presentation == .needsInput)
    }

    @Test("running count reported when nothing is blocked")
    func runningCount() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .running),
                session(id: "b", status: .running),
                session(id: "c", status: .idle)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.aggregate == .running(2))
        #expect(model.presentation == .collapsed)
    }

    @Test("all idle reported when every session is idle")
    func allIdle() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .idle),
                session(id: "b", status: .idle)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.aggregate == .allIdle)
    }

    @Test("idle + unknown mix reports as mixed, stays collapsed")
    func mixedStandby() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .idle),
                session(id: "b", status: .unknown)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.aggregate == .mixed)
        #expect(model.presentation == .collapsed)
    }

    // MARK: - Blocked selection (priority then recency)

    @Test("blocked selection picks the most recent among blocked sessions")
    func blockedPicksMostRecent() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "old", project: "old-proj", status: .needsInput, lastEventAt: 100),
                session(id: "new", project: "new-proj", status: .needsInput, lastEventAt: 900),
                session(id: "run", status: .running, lastEventAt: 999)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.blocked?.sessionID == "new")
        #expect(model.blocked?.projectName == "new-proj")
    }

    @Test("blocked carries provider + redacted detail")
    func blockedCarriesFields() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "x", provider: .codex, project: "p", status: .needsInput, detail: "Bash: xcodebuild")
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.blocked?.provider == .codex)
        #expect(model.blocked?.detail == "Bash: xcodebuild")
    }

    @Test("no blocked session leaves blocked nil even with running work")
    func noBlockedWhenOnlyRunning() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .running)]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.blocked == nil)
    }

    // MARK: - Provider dots

    @Test("one dot per provider present, coloured by highest-priority status")
    func providerDotsDedupePerProvider() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "c1", provider: .claude, status: .idle),
                session(id: "c2", provider: .claude, status: .running),
                session(id: "x1", provider: .codex, status: .needsInput)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.providerDots.count == 2)
        let claude = model.providerDots.first { $0.provider == .claude }
        let codex = model.providerDots.first { $0.provider == .codex }
        // Claude's most urgent live session is running (beats idle).
        #expect(claude?.status == .running)
        #expect(codex?.status == .needsInput)
    }

    // MARK: - Stale detection

    @Test("fresh publish is not stale")
    func freshIsNotStale() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .running)]),
            now: 1005,
            lastPublishAt: 1000
        )
        #expect(model.isStale == false)
    }

    @Test("no publish beyond the threshold is stale")
    func oldPublishIsStale() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .running)]),
            now: 1000 + MonitorHUDModel.staleThreshold + 1,
            lastPublishAt: 1000
        )
        #expect(model.isStale == true)
    }

    @Test("nil lastPublishAt is never stale (no baseline yet)")
    func nilPublishNotStale() {
        #expect(MonitorHUDModel.isStale(now: 99_999, lastPublishAt: nil) == false)
    }

    @Test("staleness is honoured even when no sessions are live")
    func staleWithNoLiveSessions() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .ended)]),
            now: 1000 + MonitorHUDModel.staleThreshold + 5,
            lastPublishAt: 1000
        )
        #expect(model.aggregate == .noSessions)
        #expect(model.isStale == true)
    }

    // MARK: - Glow decay

    @Test("glow stays full before the decay threshold")
    func glowFullEarly() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .needsInput, lastEventAt: 1000)]),
            now: 1000 + MonitorHUDModel.glowDecayThreshold - 1,
            lastPublishAt: 1000
        )
        #expect(model.blocked?.glowIntensity == 1)
    }

    @Test("glow decays to half after 60s unhandled")
    func glowDecaysLate() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .needsInput, lastEventAt: 1000)]),
            now: 1000 + MonitorHUDModel.glowDecayThreshold + 5,
            lastPublishAt: 1000
        )
        #expect(model.blocked?.glowIntensity == 0.5)
    }

    // MARK: - Wait duration (waitSince clock)

    @Test("waiting seconds derive from waitSince, not lastEventAt")
    func waitingSecondsUsesWaitSince() {
        // waitSince is far older than lastEventAt; the wait clock must win so the
        // HUD shows how long the session has actually been blocked.
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, lastEventAt: 1180, waitSince: 1000)
            ]),
            now: 1200,
            lastPublishAt: 1200
        )
        #expect(model.blocked?.waitingSeconds == 200)
    }

    @Test("waiting seconds fall back to lastEventAt when waitSince absent")
    func waitingSecondsFallsBackToLastEvent() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, lastEventAt: 1000, waitSince: nil)
            ]),
            now: 1150,
            lastPublishAt: 1150
        )
        #expect(model.blocked?.waitingSeconds == 150)
    }

    // MARK: - Blocked selection: oldest wait first

    @Test("blocked selection prefers the oldest wait when waitSince present")
    func blockedPrefersOldestWait() {
        // Two blocked sessions with wait clocks: the one waiting LONGEST (older
        // waitSince) is the most urgent, regardless of lastEventAt recency.
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "recent", project: "recent-proj", status: .needsInput,
                        lastEventAt: 1190, waitSince: 1150),
                session(id: "oldest", project: "oldest-proj", status: .needsInput,
                        lastEventAt: 1195, waitSince: 1000)
            ]),
            now: 1200,
            lastPublishAt: 1200
        )
        #expect(model.blocked?.sessionID == "oldest")
        #expect(model.blocked?.projectName == "oldest-proj")
        #expect(model.blocked?.waitingSeconds == 200)
    }

    @Test("a session with a wait clock outranks one without")
    func waitClockOutranksMissingClock() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                // No clock but very recent — under the OLD rule this would win.
                session(id: "noclock", project: "noclock", status: .needsInput,
                        lastEventAt: 1199, waitSince: nil),
                // Has a clock (older wait) — the authoritative signal wins.
                session(id: "clock", project: "clock", status: .needsInput,
                        lastEventAt: 1100, waitSince: 1050)
            ]),
            now: 1200,
            lastPublishAt: 1200
        )
        #expect(model.blocked?.sessionID == "clock")
    }

    // MARK: - Warning surfacing + priority

    @Test("fleet warning surfaces from a warned running session (no block)")
    func fleetWarningFromRunning() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .running, warning: "stale"),
                session(id: "b", status: .running)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        // A warned-but-running fleet flags itself even though nothing is blocked.
        #expect(model.warning == .stale)
        #expect(model.presentation == .collapsed)
        #expect(model.blocked == nil)
    }

    @Test("toolLoop outranks stale in the fleet warning")
    func toolLoopOutranksStale() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .running, warning: "stale"),
                session(id: "b", status: .running, warning: "toolLoop")
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.warning == .toolLoop)
    }

    @Test("no warning anywhere leaves the fleet warning nil (calm)")
    func noWarningIsCalm() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .running),
                session(id: "b", status: .idle)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.warning == nil)
    }

    @Test("unknown warning raw string maps to nil, not a phantom chip")
    func unknownWarningRawIsNil() {
        let model = MonitorHUDModel.make(
            from: snapshot([session(id: "a", status: .running, warning: "testFailing")]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.warning == nil)
    }

    @Test("blocked session carries its own warning through to the chip")
    func blockedCarriesWarning() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, waitSince: 1000, warning: "toolLoop")
            ]),
            now: 1050,
            lastPublishAt: 1050
        )
        #expect(model.blocked?.warning == .toolLoop)
    }

    // MARK: - Context pressure threshold gate

    @Test("context pressure hint hidden below the threshold")
    func contextPressureBelowThreshold() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, waitSince: 1000, contextUsedPercent: 0.5)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.blocked?.contextUsedPercent == 0.5)
        #expect(model.blocked?.showsContextPressure == false)
    }

    @Test("context pressure hint shows at/above the threshold")
    func contextPressureAtThreshold() {
        let atThreshold = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, waitSince: 1000,
                        contextUsedPercent: MonitorHUDModel.contextPressureThreshold)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(atThreshold.blocked?.showsContextPressure == true)

        let above = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, waitSince: 1000, contextUsedPercent: 0.93)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(above.blocked?.showsContextPressure == true)
    }

    @Test("nil context percent never shows a pressure hint")
    func contextPressureNilIsHidden() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "a", status: .needsInput, waitSince: 1000, contextUsedPercent: nil)
            ]),
            now: 1000,
            lastPublishAt: 1000
        )
        #expect(model.blocked?.showsContextPressure == false)
    }

    // MARK: - Priority ordering with mixed states

    @Test("mixed fleet: needsInput selected, warning surfaced, oldest wait wins")
    func mixedStatesPriority() {
        let model = MonitorHUDModel.make(
            from: snapshot([
                session(id: "run", status: .running, lastEventAt: 1195, warning: "toolLoop"),
                session(id: "wait-new", project: "new", status: .needsInput,
                        lastEventAt: 1190, waitSince: 1120),
                session(id: "wait-old", project: "old", status: .needsInput,
                        lastEventAt: 1150, waitSince: 1050, contextUsedPercent: 0.9),
                session(id: "idle", status: .idle)
            ]),
            now: 1200,
            lastPublishAt: 1200
        )
        // needsInput dominates the aggregate/presentation.
        #expect(model.aggregate == .needsInput(2))
        #expect(model.presentation == .needsInput)
        // Oldest wait is surfaced, with its own context pressure.
        #expect(model.blocked?.sessionID == "wait-old")
        #expect(model.blocked?.showsContextPressure == true)
        // The running session's tool-loop still flags the collapsed row.
        #expect(model.warning == .toolLoop)
    }
}
