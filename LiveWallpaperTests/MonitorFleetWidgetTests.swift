import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

/// Pure-logic tests for the Fleet widget — no UI. They pin the parts a 1:1 mock
/// replica must get exactly right: row ordering (§3.2.4), Action-Strip aggregation,
/// the in-status timer SOURCE per status, the context-pressure band thresholds,
/// warning-chip mapping and the M row cap. Static helpers are `nonisolated` so
/// they run off the main actor.
final class MonitorFleetWidgetTests: XCTestCase {

    // MARK: Fixtures

    private static let now: Double = 1_000_000

    private func session(
        _ id: String,
        _ status: MonitorAgentStatus,
        provider: MonitorAgentProvider = .claude,
        name: String = "proj",
        lastEventAt: Double = now,
        startedAt: Double? = nil,
        waitSince: Double? = nil,
        cost: Double? = nil,
        ctx: Double? = nil,
        warning: String? = nil,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        statusDetail: String? = nil
    ) -> MonitorAgentSessionState {
        var s = MonitorAgentSessionState(
            id: id, provider: provider, projectName: name,
            status: status, lastEventAt: lastEventAt, processAlive: status != .ended)
        s.startedAt = startedAt
        s.waitSince = waitSince
        s.costUSD = cost
        s.contextUsedPercent = ctx
        s.warning = warning
        s.tokens = MonitorTokenTotals(input: tokensIn, output: tokensOut)
        s.statusDetail = statusDetail
        return s
    }

    // MARK: Row ordering (§3.2.4: needsInput > running > idle > ended, then recency)

    func testSortOrdersByAttentionThenRecency() {
        let sessions = [
            session("a", .ended, lastEventAt: 500),
            session("b", .running, lastEventAt: 100),
            session("c", .needsInput, lastEventAt: 50),
            session("d", .idle, lastEventAt: 900),
            session("e", .running, lastEventAt: 400),
        ]
        let ids = MonitorFleetWidgetView.sorted(sessions).map(\.id)
        // needsInput first, then the two running by lastEventAt desc (e before b),
        // then idle, then ended.
        XCTAssertEqual(ids, ["c", "e", "b", "d", "a"])
    }

    func testSortIsStableWithinEqualPriorityByRecency() {
        let sessions = [
            session("old", .running, lastEventAt: 10),
            session("new", .running, lastEventAt: 90),
            session("mid", .running, lastEventAt: 50),
        ]
        XCTAssertEqual(MonitorFleetWidgetView.sorted(sessions).map(\.id), ["new", "mid", "old"])
    }

    func testUnknownSortsBelowIdleAboveEnded() {
        let sessions = [
            session("ended", .ended),
            session("unknown", .unknown),
            session("idle", .idle),
        ]
        // attentionPriority: idle 2 > unknown 1 > ended 0.
        XCTAssertEqual(MonitorFleetWidgetView.sorted(sessions).map(\.id), ["idle", "unknown", "ended"])
    }

    // MARK: M row cap (top 3 non-idle) + "+N more" accounting

    func testMediumRowsDropIdleAndCapAtThree() {
        let sorted = MonitorFleetWidgetView.sorted([
            session("need", .needsInput),
            session("run1", .running, lastEventAt: 90),
            session("run2", .running, lastEventAt: 80),
            session("run3", .running, lastEventAt: 70),
            session("idle", .idle),
            session("ended", .ended),
        ])
        let rows = MonitorFleetWidgetView.mediumRows(sorted)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.id), ["need", "run1", "run2"])
        // idle is never a row; the "+N more" whisper counts everything left off.
        XCTAssertFalse(rows.contains { $0.status == .idle })
    }

    func testMediumRowsKeepsEndedWhenRoom() {
        let sorted = MonitorFleetWidgetView.sorted([
            session("need", .needsInput),
            session("ended", .ended),
            session("idle", .idle),
        ])
        XCTAssertEqual(MonitorFleetWidgetView.mediumRows(sorted).map(\.id), ["need", "ended"])
    }

    // MARK: Counts

    func testCountsBucketByStatus() {
        let c = MonitorFleetWidgetView.counts([
            session("1", .running), session("2", .running), session("3", .running),
            session("4", .needsInput),
            session("5", .idle), session("6", .idle),
            session("7", .ended),
            session("8", .unknown),
        ])
        XCTAssertEqual(c.running, 3)
        XCTAssertEqual(c.needsInput, 1)
        XCTAssertEqual(c.idle, 2)
        XCTAssertEqual(c.ended, 1)
        XCTAssertEqual(c.unknown, 1)
    }

    // MARK: Action-Strip aggregation (cost sums non-ended; longest = running only)

    func testTotalsSumLiveCostAndLongestRun() {
        let sessions = [
            session("need", .needsInput, startedAt: Self.now - 410, cost: 1.08),
            session("burn", .running, startedAt: Self.now - 192, cost: 2.14, warning: "toolLoop"),
            session("prod", .running, startedAt: Self.now - 47, cost: 0.38),
            session("ended", .ended, startedAt: Self.now - 600, cost: 0.51), // excluded from cost
        ]
        let t = MonitorFleetWidgetView.totals(sessions, now: Self.now)
        // Live spend = 1.08 + 2.14 + 0.38 (ended 0.51 excluded).
        XCTAssertEqual(t.cost, 1.08 + 2.14 + 0.38, accuracy: 0.0001)
        // Longest = the 192s running session (needsInput's 410s doesn't count —
        // only running sessions contribute to the live elapsed metric).
        XCTAssertEqual(t.longest, 192, accuracy: 0.5)
        XCTAssertTrue(t.anyWarn)
    }

    func testTotalsNoWarnWhenNoneCarryWarning() {
        let t = MonitorFleetWidgetView.totals([
            session("r", .running, startedAt: Self.now - 10, cost: 0.1),
        ], now: Self.now)
        XCTAssertFalse(t.anyWarn)
        XCTAssertEqual(t.cost, 0.1, accuracy: 0.0001)
    }

    // MARK: In-status timer SOURCE selection

    func testRunningTimerSourcesFromStartedAt() {
        let s = session("r", .running, lastEventAt: Self.now - 3, startedAt: Self.now - 125)
        let timer = MonitorFleetWidgetView.timerText(for: s, now: Self.now)
        XCTAssertEqual(timer?.source, .running)
        // 125s → 02:05 (elapsed from startedAt, NOT the 3s-ago lastEventAt).
        XCTAssertEqual(timer?.text, "02:05")
    }

    func testNeedsInputTimerSourcesFromWaitSince() {
        let s = session("n", .needsInput, waitSince: Self.now - 34)
        let timer = MonitorFleetWidgetView.timerText(for: s, now: Self.now)
        XCTAssertEqual(timer?.source, .waiting)
        XCTAssertTrue(timer?.text.contains("00:34") ?? false, "waiting timer should read since waitSince")
    }

    func testEndedTimerIsFinishedAgoFromLastEvent() {
        let s = session("e", .ended, lastEventAt: Self.now - 130)
        let timer = MonitorFleetWidgetView.timerText(for: s, now: Self.now)
        XCTAssertEqual(timer?.source, .finished)
        XCTAssertTrue(timer?.text.contains("2m") ?? false, "ended shows a compact 'finished 2m ago'")
    }

    func testIdleHasNoTimer() {
        XCTAssertNil(MonitorFleetWidgetView.timerText(for: session("i", .idle), now: Self.now))
    }

    func testRunningWithoutStartedAtHasNoTimer() {
        XCTAssertNil(MonitorFleetWidgetView.timerText(for: session("r", .running, startedAt: nil), now: Self.now))
    }

    // MARK: Context-pressure band thresholds + live-only suppression

    func testContextBandThresholds() {
        XCTAssertEqual(MonitorFleetWidgetView.contextBand(for: session("a", .running, ctx: 0.50))?.band, .normal)
        XCTAssertEqual(MonitorFleetWidgetView.contextBand(for: session("b", .running, ctx: 0.75))?.band, .warn)
        XCTAssertEqual(MonitorFleetWidgetView.contextBand(for: session("c", .running, ctx: 0.89))?.band, .warn)
        XCTAssertEqual(MonitorFleetWidgetView.contextBand(for: session("d", .running, ctx: 0.90))?.band, .crit)
        XCTAssertEqual(MonitorFleetWidgetView.contextBand(for: session("e", .running, ctx: 0.91))?.percentText, "91%")
    }

    func testContextBandSuppressedForNonLiveSessions() {
        // idle / ended aren't "about to compact" → no bar even with a ctx value.
        XCTAssertNil(MonitorFleetWidgetView.contextBand(for: session("i", .idle, ctx: 0.8)))
        XCTAssertNil(MonitorFleetWidgetView.contextBand(for: session("e", .ended, ctx: 0.8)))
        // needsInput is live → present.
        XCTAssertNotNil(MonitorFleetWidgetView.contextBand(for: session("n", .needsInput, ctx: 0.47)))
    }

    func testContextBandNilWhenPercentAbsent() {
        XCTAssertNil(MonitorFleetWidgetView.contextBand(for: session("r", .running, ctx: nil)))
    }

    // MARK: Warning-chip mapping

    func testWarningChipMapsKnownTokens() {
        let loop = MonitorFleetWidgetView.warningLabel(for: session("a", .running, warning: "toolLoop"))
        XCTAssertEqual(loop?.text, "tool loop")
        XCTAssertFalse(loop?.isStale ?? true)

        let stale = MonitorFleetWidgetView.warningLabel(for: session("b", .running, warning: "stale"))
        XCTAssertEqual(stale?.text, "stale")
        XCTAssertTrue(stale?.isStale ?? false)
    }

    func testWarningChipPassesThroughUnknownTokenAndNilWhenEmpty() {
        XCTAssertEqual(MonitorFleetWidgetView.warningLabel(for: session("a", .running, warning: "testFailing"))?.text,
                       "testFailing")
        XCTAssertNil(MonitorFleetWidgetView.warningLabel(for: session("b", .running, warning: nil)))
        XCTAssertNil(MonitorFleetWidgetView.warningLabel(for: session("c", .running, warning: "")))
    }

    // MARK: Most-urgent (S aggregate) selection

    func testMostUrgentPrefersLongestWaitingNeedsInput() {
        let sessions = [
            session("run", .running, startedAt: Self.now - 500),
            session("waitShort", .needsInput, waitSince: Self.now - 10),
            session("waitLong", .needsInput, waitSince: Self.now - 200),
        ]
        XCTAssertEqual(MonitorFleetWidgetView.mostUrgent(sessions)?.id, "waitLong")
    }

    func testMostUrgentFallsBackToLongestRunningWhenNoneBlocked() {
        let sessions = [
            session("young", .running, startedAt: Self.now - 30),
            session("old", .running, startedAt: Self.now - 300),
            session("idle", .idle),
        ]
        XCTAssertEqual(MonitorFleetWidgetView.mostUrgent(sessions)?.id, "old")
    }

    func testMostUrgentNilWhenOnlyIdleOrEnded() {
        XCTAssertNil(MonitorFleetWidgetView.mostUrgent([
            session("i", .idle), session("e", .ended),
        ]))
    }

    // MARK: Budget text

    func testBudgetTextComposesCostAndTokens() {
        let s = session("a", .running, cost: 1.08, tokensIn: 80000, tokensOut: 5000)
        // usd(1.08) = "$1.08"; tokens(85000) = "85K".
        XCTAssertEqual(MonitorFleetWidgetView.budgetText(for: s), "$1.08 · 85K tok")
    }

    func testBudgetTextOmitsMissingParts() {
        XCTAssertEqual(MonitorFleetWidgetView.budgetText(for: session("a", .running, cost: 0.5)), "$0.50")
        // tokens(21500) rounds to 22K (%.0fK for n ≥ 10 000).
        XCTAssertEqual(MonitorFleetWidgetView.budgetText(for: session("b", .running, tokensIn: 20000, tokensOut: 1500)),
                       "22K tok")
        XCTAssertEqual(MonitorFleetWidgetView.budgetText(for: session("c", .idle)), "")
    }

    // MARK: L row list (all statuses, capped) + "+N more" accounting

    func testLargeRowsKeepIdleAndEndedAndCap() {
        let sorted = MonitorFleetWidgetView.sorted([
            session("need", .needsInput),
            session("run1", .running, lastEventAt: 90),
            session("run2", .running, lastEventAt: 80),
            session("idle", .idle),
            session("ended", .ended),
        ])
        let rows = MonitorFleetWidgetView.largeRows(sorted, cap: 6)
        // Unlike M, idle/ended stay in the list (they collapse when rendered).
        XCTAssertEqual(rows.map(\.id), ["need", "run1", "run2", "idle", "ended"])
        XCTAssertEqual(MonitorFleetWidgetView.largeRows(sorted, cap: 3).map(\.id), ["need", "run1", "run2"])
        XCTAssertEqual(MonitorFleetWidgetView.largeRows(sorted, cap: 0).count, 0)
    }

    // MARK: Settings — provider filter

    func testProviderFilterReadsOption() {
        XCTAssertEqual(MonitorFleetWidgetView.providerFilter([:]), nil)
        XCTAssertEqual(MonitorFleetWidgetView.providerFilter(["fleetProvider": .string("claude")]), .claude)
        XCTAssertEqual(MonitorFleetWidgetView.providerFilter(["fleetProvider": .string("codex")]), .codex)
        // Unknown / malformed → treat as "all".
        XCTAssertEqual(MonitorFleetWidgetView.providerFilter(["fleetProvider": .string("gemini")]), nil)
    }

    func testFilteredByProvider() {
        let all = [
            session("c1", .running, provider: .claude),
            session("x1", .running, provider: .codex),
            session("c2", .idle, provider: .claude),
        ]
        XCTAssertEqual(MonitorFleetWidgetView.filtered(all, provider: nil).count, 3)
        XCTAssertEqual(MonitorFleetWidgetView.filtered(all, provider: .claude).map(\.id), ["c1", "c2"])
        XCTAssertEqual(MonitorFleetWidgetView.filtered(all, provider: .codex).map(\.id), ["x1"])
    }

    // MARK: Settings — sort mode

    func testSortModeReadsOption() {
        XCTAssertEqual(MonitorFleetWidgetView.sortMode([:]), .attention)
        XCTAssertEqual(MonitorFleetWidgetView.sortMode(["fleetSort": .string("recent")]), .recent)
        XCTAssertEqual(MonitorFleetWidgetView.sortMode(["fleetSort": .string("cost")]), .cost)
        XCTAssertEqual(MonitorFleetWidgetView.sortMode(["fleetSort": .string("bogus")]), .attention)
    }

    func testSortByRecentIgnoresAttentionPriority() {
        let sessions = [
            session("oldNeed", .needsInput, lastEventAt: 10),
            session("newRun", .running, lastEventAt: 90),
            session("midIdle", .idle, lastEventAt: 50),
        ]
        // recent mode is purely lastEventAt desc — needsInput does NOT jump the queue.
        XCTAssertEqual(MonitorFleetWidgetView.sorted(sessions, mode: .recent).map(\.id),
                       ["newRun", "midIdle", "oldNeed"])
    }

    func testSortByCostDescendsWithNilAndEndedSinking() {
        let sessions = [
            session("cheap", .running, lastEventAt: 10, cost: 0.2),
            session("pricey", .running, lastEventAt: 20, cost: 3.0),
            session("free", .running, lastEventAt: 30, cost: nil),
        ]
        // Highest live spend first; nil cost sinks to the bottom.
        XCTAssertEqual(MonitorFleetWidgetView.sorted(sessions, mode: .cost).map(\.id),
                       ["pricey", "cheap", "free"])
    }

    func testSortAttentionModeMatchesDefaultSort() {
        let sessions = [
            session("a", .ended, lastEventAt: 500),
            session("b", .running, lastEventAt: 100),
            session("c", .needsInput, lastEventAt: 50),
        ]
        XCTAssertEqual(MonitorFleetWidgetView.sorted(sessions, mode: .attention).map(\.id),
                       MonitorFleetWidgetView.sorted(sessions).map(\.id))
    }

    // MARK: Settings — row cap

    func testRowCapClampsToFallbackAndFloor() {
        // Unset → fallback.
        XCTAssertEqual(MonitorFleetWidgetView.rowCap([:], fallback: 6), 6)
        XCTAssertEqual(MonitorFleetWidgetView.rowCap([:], fallback: 3), 3)
        // Within range → honoured.
        XCTAssertEqual(MonitorFleetWidgetView.rowCap(["fleetMaxRows": .number(4)], fallback: 6), 4)
        // Above the size's mock max → clamped down to fallback.
        XCTAssertEqual(MonitorFleetWidgetView.rowCap(["fleetMaxRows": .number(9)], fallback: 6), 6)
        XCTAssertEqual(MonitorFleetWidgetView.rowCap(["fleetMaxRows": .number(4)], fallback: 3), 3)
        // Below 1 → clamped up to 1.
        XCTAssertEqual(MonitorFleetWidgetView.rowCap(["fleetMaxRows": .number(0)], fallback: 6), 1)
    }

    // MARK: Recent-tool tint mapping

    func testToolTintMapsResultFlag() {
        XCTAssertEqual(MonitorFleetWidgetView.toolTint(true), MonitorDesign.inkMuted)
        XCTAssertEqual(MonitorFleetWidgetView.toolTint(nil), MonitorDesign.inkFaint)
        XCTAssertNotEqual(MonitorFleetWidgetView.toolTint(false), MonitorDesign.inkMuted)
    }
}
