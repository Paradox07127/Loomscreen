import Foundation

/// Pure, UI-free derivation of what the floating fleet HUD should show for a given `MonitorSnapshot`.
struct MonitorHUDModel: Equatable {

    /// Collapsed vs expanded is driven purely by whether the fleet currently needs the user — never by hover (hover only affects opacity, a view-only concern).
    enum Presentation: Equatable {
        case collapsed
        case needsInput
    }

    /// One coloured dot in the collapsed pill — one per provider actually present.
    struct ProviderDot: Equatable, Identifiable {
        let provider: MonitorAgentProvider
        let status: MonitorAgentStatus
        var id: MonitorAgentProvider { provider }
    }

    /// A derived anomaly a session is exhibiting, surfaced as one subtle chip.
    enum Warning: Equatable {
        /// Spinning in place — the agent keeps retrying one tool (burning, no progress).
        case toolLoop
        /// Quiet stall — running + alive but silent past the stale threshold.
        case stale

        init?(raw: String?) {
            switch raw {
            case "toolLoop": self = .toolLoop
            case "stale": self = .stale
            default: return nil
            }
        }
    }

    /// The single blocked session surfaced in the expanded state.
    struct BlockedSession: Equatable {
        let sessionID: String
        let provider: MonitorAgentProvider
        let projectName: String
        /// Tool-name / short verb only (already privacy-redacted upstream).
        let detail: String?
        /// Seconds the session has been waiting.
        let waitingSeconds: Double?
        /// This session's own anomaly, if any — surfaced as a chip in the urgent
        /// section alongside the wait time.
        let warning: Warning?
        /// Last-turn context fill (0…1); the view shows a pressure hint only once
        /// it crosses `contextPressureThreshold` (near-compaction), else nothing.
        let contextUsedPercent: Double?
    }

    let presentation: Presentation
    let providerDots: [ProviderDot]
    /// e.g. "3 running", "all idle", "no active sessions" — already resolved to
    /// a semantic case the view localizes.
    let aggregate: Aggregate
    let blocked: BlockedSession?
    /// The single most urgent anomaly across live sessions, surfaced as a subtle collapsed-row chip so "who's stuck" reads at a glance even when nobody is blocked.
    let warning: Warning?
    /// True when the broker hasn't published in `staleThreshold`; the view dims
    /// and appends a "stale" note.
    let isStale: Bool

    /// Semantic fleet summary the view maps to localized copy. Avoids baking
    /// user-facing strings into this pure layer.
    enum Aggregate: Equatable {
        case noSessions
        case running(Int)
        case needsInput(Int)
        case allIdle
        // A live mix of idle/unknown, nothing running or blocked. `.ended`
        // sessions are filtered before aggregation, so there is no "all done".
        case mixed
    }

    /// No agents present at all (module off, unauthorized, or genuinely empty).
    static let empty = MonitorHUDModel(
        presentation: .collapsed,
        providerDots: [],
        aggregate: .noSessions,
        blocked: nil,
        warning: nil,
        isStale: false
    )
}

extension MonitorHUDModel {
    /// Publish is considered stale after this long with no fresh snapshot.
    static let staleThreshold: TimeInterval = 10

    /// After this long unhandled, the coral breathing glow decays (~50%).
    static let glowDecayThreshold: TimeInterval = 60

    /// Context fill at/above which the HUD shows a near-compaction pressure hint
    /// for the focused session. Below it: nothing (calm).
    static let contextPressureThreshold: Double = 0.8

    /// Sessions in these states are "live" for provider-dot / counting purposes.
    private static func isLive(_ status: MonitorAgentStatus) -> Bool {
        switch status {
        case .running, .needsInput, .idle, .unknown: return true
        case .ended: return false
        }
    }

    /// Builds the model from a snapshot. `now`/`lastPublishAt` are injected so
    /// staleness is testable without a clock.
    static func make(
        from snapshot: MonitorSnapshot?,
        now: Double,
        lastPublishAt: Double?
    ) -> MonitorHUDModel {
        guard let snapshot, let agents = snapshot.agents else { return .empty }

        let live = agents.filter { isLive($0.status) }
        guard !live.isEmpty else {
            // Module is on but nothing is running — still honor staleness so a
            // dead pipeline reads as stale rather than a confident "no sessions".
            let stale = isStale(now: now, lastPublishAt: lastPublishAt)
            return MonitorHUDModel(
                presentation: .collapsed,
                providerDots: [],
                aggregate: .noSessions,
                blocked: nil,
                warning: nil,
                isStale: stale
            )
        }

        let dots = providerDots(from: live)
        let aggregate = aggregate(from: live)
        let blocked = selectBlocked(from: live, now: now)
        let presentation: Presentation = (blocked != nil) ? .needsInput : .collapsed
        let warning = fleetWarning(from: live)
        let stale = isStale(now: now, lastPublishAt: lastPublishAt)

        return MonitorHUDModel(
            presentation: presentation,
            providerDots: dots,
            aggregate: aggregate,
            blocked: blocked,
            warning: warning,
            isStale: stale
        )
    }

    static func isStale(now: Double, lastPublishAt: Double?) -> Bool {
        guard let lastPublishAt else { return false }
        return (now - lastPublishAt) > staleThreshold
    }

    /// One dot per provider present, each carrying that provider's highest-
    /// priority live status so the dot colour reflects the most urgent work.
    private static func providerDots(from live: [MonitorAgentSessionState]) -> [ProviderDot] {
        MonitorAgentProvider.allCases.compactMap { provider in
            let forProvider = live.filter { $0.provider == provider }
            guard let top = forProvider.max(by: {
                $0.status.attentionPriority < $1.status.attentionPriority
            }) else { return nil }
            return ProviderDot(provider: provider, status: top.status)
        }
    }

    private static func aggregate(from live: [MonitorAgentSessionState]) -> Aggregate {
        let needing = live.filter { $0.status == .needsInput }.count
        if needing > 0 { return .needsInput(needing) }

        let running = live.filter { $0.status == .running }.count
        if running > 0 { return .running(running) }

        let idle = live.filter { $0.status == .idle }.count
        if idle == live.count { return .allIdle }

        return .mixed
    }

    private static func selectBlocked(
        from live: [MonitorAgentSessionState],
        now: Double
    ) -> BlockedSession? {
        let blocked = live.filter { $0.status == .needsInput }
        guard let winner = blocked.max(by: isLessUrgentBlocked) else { return nil }

        // Providers without a wait clock fall back to their last event time.
        let waitStart = winner.waitSince ?? winner.lastEventAt
        let waiting = max(0, now - waitStart)
        return BlockedSession(
            sessionID: winner.id,
            provider: winner.provider,
            projectName: winner.projectName,
            detail: winner.statusDetail,
            waitingSeconds: waiting,
            warning: Warning(raw: winner.warning),
            contextUsedPercent: winner.contextUsedPercent
        )
    }

    /// Ordering predicate for `max(by:)` over blocked sessions: returns true when `lhs` is LESS urgent than `rhs` (so `max` yields the most urgent).
    private static func isLessUrgentBlocked(
        _ lhs: MonitorAgentSessionState,
        _ rhs: MonitorAgentSessionState
    ) -> Bool {
        switch (lhs.waitSince, rhs.waitSince) {
        case let (l?, r?):
            return l > r
        case (nil, .some):
            return true          // lhs (no clock) is less urgent than rhs (has clock)
        case (.some, nil):
            return false         // lhs (has clock) is more urgent
        case (nil, nil):
            return lhs.lastEventAt < rhs.lastEventAt
        }
    }

    /// The single most urgent anomaly across live sessions, for the collapsed-row chip.
    private static func fleetWarning(from live: [MonitorAgentSessionState]) -> Warning? {
        let warnings = live.compactMap { Warning(raw: $0.warning) }
        if warnings.contains(.toolLoop) { return .toolLoop }
        if warnings.contains(.stale) { return .stale }
        return nil
    }
}

extension MonitorHUDModel.BlockedSession {
    /// Glow starts at full and decays to ~50% once the wait passes the decay threshold, so a long-unhandled prompt fades rather than pulsing forever.
    var glowIntensity: Double {
        guard let waitingSeconds else { return 1 }
        guard waitingSeconds >= MonitorHUDModel.glowDecayThreshold else { return 1 }
        return 0.5
    }

    /// True only when the focused session is near compaction — the gate for the
    /// pressure hint. Below the threshold (or unknown) the view shows nothing.
    var showsContextPressure: Bool {
        guard let contextUsedPercent else { return false }
        return contextUsedPercent >= MonitorHUDModel.contextPressureThreshold
    }
}
