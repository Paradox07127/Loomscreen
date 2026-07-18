import Foundation

/// Sliding-window QoS decision logic for the render thread. The render thread runs
/// its frame body with huge headroom (Release p95 ≈ 4.2ms vs a 16.7ms/60fps
/// budget), so pinning it at `.userInteractive` keeps it on the P-cores and burns
/// power for nothing. This state machine lets the thread ride the E-cores
/// (`.utility`) by default and only climb to `.userInteractive` when a measured
/// p95 shows it actually needs the P-cores to hold cadence.
///
/// Pure logic, no `pthread` calls: the owner (`WPERenderThread`) applies the
/// returned level. NOT thread-safe by design — every method is invoked on the one
/// render thread that owns the instance, so no lock is needed. Falsifiable: if a
/// method is ever called off that thread the ring buffer races.
struct WPEAdaptiveRenderQoS {

    /// The two QoS tiers the thread moves between. `.economy` maps to
    /// `.utility` (E-core eligible); `.high` to `.userInteractive` (P-core).
    enum Level: Equatable {
        case economy
        case high
    }

    // Hysteresis band, as fractions of the frame budget. Raise > lower keeps a
    // dead zone (35%–60% of budget) between the two triggers so the level can't
    // flap frame-to-frame: a P-core reading (~25% of budget) drops us to economy,
    // an E-core reading (~50%) sits inside the band and holds economy. Only a
    // genuine overrun (>60%) climbs back to high.
    private let raiseFraction: Double
    private let lowerFraction: Double
    private let windowSize: Int

    /// Frame budget in seconds (1 / target-fps). Updated when the display's
    /// preferred cadence changes so a 30fps wallpaper isn't judged against a
    /// 60fps budget.
    private var budgetSeconds: Double

    // Fixed-size ring buffer of recent frame-body durations (seconds).
    private var samples: [Double]
    private var writeIndex = 0
    private var sampleCount = 0

    /// Frames still owed a forced `.high` (scene load / reload warm-up: the first
    /// frames after a load pay the lazy GLSL→MSL transpile and must not be judged
    /// on E-core timing). Counts down one per recorded frame.
    private var boostFramesRemaining = 0

    /// When false the thread is pinned at `.high` forever (the escape hatch):
    /// `record` never returns a downgrade, so behaviour is byte-for-byte the old
    /// fixed `.userInteractive` thread.
    let isEnabled: Bool

    private(set) var level: Level

    init(
        isEnabled: Bool,
        budgetSeconds: Double = 1.0 / 60.0,
        raiseFraction: Double = 0.60,
        lowerFraction: Double = 0.35,
        windowSize: Int = 90
    ) {
        self.isEnabled = isEnabled
        self.budgetSeconds = budgetSeconds > 0 ? budgetSeconds : 1.0 / 60.0
        self.raiseFraction = raiseFraction
        self.lowerFraction = lowerFraction
        self.windowSize = max(1, windowSize)
        self.samples = [Double](repeating: 0, count: max(1, windowSize))
        // Disabled ⇒ pinned high. Enabled ⇒ start economy and let the window earn
        // a promotion, so a light scene never spends a frame on the P-cores.
        self.level = isEnabled ? .economy : .high
    }

    /// Point the budget at the live cadence (called when preferred fps changes).
    mutating func setBudget(seconds: Double) {
        guard seconds > 0 else { return }
        budgetSeconds = seconds
    }

    /// Force `.high` for the next `frames` recorded frames (load/reload warm-up).
    /// Extends, never shortens, an in-flight boost.
    mutating func boost(frames: Int) {
        boostFramesRemaining = max(boostFramesRemaining, max(0, frames))
    }

    /// Record one frame-body duration and return the new level iff it changed
    /// (so the owner applies `pthread_set_qos_class_self_np` only on a transition).
    mutating func record(frameDuration seconds: Double) -> Level? {
        guard isEnabled else { return nil } // pinned high; nothing to decide
        samples[writeIndex] = max(0, seconds)
        writeIndex = (writeIndex + 1) % windowSize
        sampleCount = min(sampleCount + 1, windowSize)

        if boostFramesRemaining > 0 {
            boostFramesRemaining -= 1
            return promote(to: .high)
        }

        let p95 = percentile95()
        switch level {
        case .economy:
            if p95 > budgetSeconds * raiseFraction { return promote(to: .high) }
        case .high:
            if p95 < budgetSeconds * lowerFraction { return promote(to: .economy) }
        }
        return nil
    }

    private mutating func promote(to newLevel: Level) -> Level? {
        guard level != newLevel else { return nil }
        level = newLevel
        return newLevel
    }

    /// p95 over the current window. Small window (≤90) ⇒ a per-frame copy+sort is
    /// well under a microsecond, negligible against the frame it guards.
    private func percentile95() -> Double {
        guard sampleCount > 0 else { return 0 }
        let window = sampleCount < windowSize
            ? Array(samples[0..<sampleCount])
            : samples
        let sorted = window.sorted()
        // Nearest-rank: index of the 95th percentile, clamped to the last element.
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    #if DEBUG
    var boostFramesRemainingForTesting: Int { boostFramesRemaining }
    #endif
}
