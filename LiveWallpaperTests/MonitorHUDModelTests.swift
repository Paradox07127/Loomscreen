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
        lastEventAt: Double = 1000
    ) -> MonitorAgentSessionState {
        MonitorAgentSessionState(
            id: id,
            provider: provider,
            projectName: project,
            status: status,
            statusDetail: detail,
            lastEventAt: lastEventAt,
            processAlive: true
        )
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
}
