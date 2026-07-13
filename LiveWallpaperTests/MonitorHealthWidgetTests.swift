import Testing
import Foundation
@testable import LiveWallpaper

/// Pure-logic coverage for the Health widget's view-model — the state→colour map,
/// worst-first ordering, source-name mapping and freshness honesty (the visual
/// layout is exercised by the SwiftUI previews, not here).
@Suite("Monitor health widget")
struct MonitorHealthWidgetTests {

    private func source(_ id: String, _ state: String, at: Double? = nil) -> MonitorSourceHealth {
        MonitorSourceHealth(sourceID: id, state: state, detail: nil, lastUpdateAt: at)
    }

    // MARK: - State → dot colour (mock .dotmx .hs i.<state>)

    @Test("Dot colour maps each state to its design token")
    func dotColorMapping() {
        #expect(MonitorHealthModel.dotColor("ok") == MonitorDesign.signalSage)
        #expect(MonitorHealthModel.dotColor("stale") == MonitorDesign.signalAmber)
        #expect(MonitorHealthModel.dotColor("unauthorized") == MonitorDesign.signalCoral)
        #expect(MonitorHealthModel.dotColor("error") == MonitorDesign.signalRed)
        #expect(MonitorHealthModel.dotColor("off") == MonitorDesign.signalIdle)
        #expect(MonitorHealthModel.dotColor("garbage") == MonitorDesign.signalIdle)
    }

    @Test("Word colour: only ok(sage)/unauthorized(coral) tint; rest faint")
    func wordColorMapping() {
        #expect(MonitorHealthModel.wordColor("ok") == MonitorDesign.signalSage)
        #expect(MonitorHealthModel.wordColor("unauthorized") == MonitorDesign.signalCoral)
        #expect(MonitorHealthModel.wordColor("stale") == MonitorDesign.inkFaint)
        #expect(MonitorHealthModel.wordColor("error") == MonitorDesign.inkFaint)
        #expect(MonitorHealthModel.wordColor("off") == MonitorDesign.inkFaint)
    }

    @Test("Only ok/stale/unauthorized dots glow; error/off are matte")
    func glowSplit() {
        #expect(MonitorHealthModel.glows("ok"))
        #expect(MonitorHealthModel.glows("stale"))
        #expect(MonitorHealthModel.glows("unauthorized"))
        #expect(!MonitorHealthModel.glows("error"))
        #expect(!MonitorHealthModel.glows("off"))
    }

    // MARK: - Ordering (worst first, stable within a band)

    @Test("Ordered puts failures first, ok last, stable within priority")
    func worstFirstOrdering() {
        let input = [
            source("system", "ok"),
            source("claude", "ok"),
            source("codex", "unauthorized"),
            source("net", "stale"),
        ]
        let ordered = MonitorHealthModel.ordered(input).map(\.sourceID)
        #expect(ordered == ["codex", "net", "system", "claude"])
    }

    @Test("Ordering priority: unauthorized > error > stale > off > ok")
    func priorityRanking() {
        #expect(MonitorHealthModel.priority("unauthorized") > MonitorHealthModel.priority("error"))
        #expect(MonitorHealthModel.priority("error") > MonitorHealthModel.priority("stale"))
        #expect(MonitorHealthModel.priority("stale") > MonitorHealthModel.priority("off"))
        #expect(MonitorHealthModel.priority("off") > MonitorHealthModel.priority("ok"))
    }

    // MARK: - Counts, wording, attention

    @Test("okCount counts only ok sources")
    func okCounting() {
        let list = [source("a", "ok"), source("b", "stale"), source("c", "ok"), source("d", "error")]
        #expect(MonitorHealthModel.okCount(list) == 2)
    }

    @Test("State word is 'ok' for ok, raw string otherwise")
    func stateWording() {
        #expect(MonitorHealthModel.stateWord("ok") == "ok")
        #expect(MonitorHealthModel.stateWord("stale") == "stale")
        #expect(MonitorHealthModel.stateWord("unauthorized") == "unauthorized")
        #expect(MonitorHealthModel.stateWord("off") == "off")
    }

    @Test("needsAttention true only for unauthorized/error")
    func attentionFlag() {
        #expect(MonitorHealthModel.needsAttention("unauthorized"))
        #expect(MonitorHealthModel.needsAttention("error"))
        #expect(!MonitorHealthModel.needsAttention("stale"))
        #expect(!MonitorHealthModel.needsAttention("ok"))
        #expect(!MonitorHealthModel.needsAttention("off"))
    }

    // MARK: - Header dot (mock chd(…, un?"crit":"") — ALWAYS renders once there's data)

    @Test("Header dot: sage baseline when nominal, coral the moment something needs attention")
    func headerDotColorMapping() {
        #expect(MonitorHealthModel.headerDotColor(needsAttention: false) == MonitorDesign.signalSage)
        #expect(MonitorHealthModel.headerDotColor(needsAttention: true) == MonitorDesign.signalCoral)
    }

    // MARK: - Display names

    @Test("Display name maps known source IDs to friendly labels")
    func displayNameMapping() {
        #expect(MonitorHealthModel.displayName("system") == "System")
        #expect(MonitorHealthModel.displayName("claude") == "Claude")
        #expect(MonitorHealthModel.displayName("codex") == "Codex")
        #expect(MonitorHealthModel.displayName("usage") == "Usage")
        // Unknown IDs fall back to capitalized-first, never blank.
        #expect(MonitorHealthModel.displayName("weather") == "Weather")
        #expect(MonitorHealthModel.displayName("") == "")
    }

    // MARK: - Freshness honesty

    @Test("Freshest age picks the smallest non-negative age, nil when none")
    func freshestAgeHonesty() {
        let now = 1_000.0
        let withTimes = [
            source("a", "ok", at: now - 30),
            source("b", "ok", at: now - 3),
            source("c", "stale", at: now - 120),
        ]
        #expect(MonitorHealthModel.freshestAge(withTimes, now: now) == 3)

        // No timestamps → nil (never a fabricated "1s ago").
        let noTimes = [source("a", "ok"), source("b", "stale")]
        #expect(MonitorHealthModel.freshestAge(noTimes, now: now) == nil)

        // A future timestamp (clock skew) is ignored, not shown as negative.
        let skewed = [source("a", "ok", at: now + 50), source("b", "ok", at: now - 8)]
        #expect(MonitorHealthModel.freshestAge(skewed, now: now) == 8)
    }
}
