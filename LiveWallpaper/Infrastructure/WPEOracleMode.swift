#if !LITE_BUILD
import Foundation
import simd

/// Central switch for the WPE render oracle — the same-machine refactor-safety
/// self-oracle and the Mac↔Windows fidelity capture share it. When enabled the
/// render path becomes deterministic: particle RNG is seeded, the frame clock is
/// frozen to a fixed time, and per-pass output hashes are recorded, so two runs
/// of unchanged code produce byte-identical `WPECanonicalTraceRecorder` traces.
///
/// DEBUG-only: in Release (and Lite, where this file is absent) every accessor is
/// inert, so the production render path is byte-for-byte unchanged — particles keep
/// the system CSPRNG, the clock keeps advancing, and no extra snapshotting runs.
enum WPEOracleMode {
    #if DEBUG
    /// Forces `isEnabled` independent of UserDefaults so the test suite is never at the
    /// mercy of a developer's persisted `WPEOracleEnabled` (which would otherwise freeze
    /// the clock / seed particles inside renderer tests). Pass nil to clear.
    nonisolated(unsafe) static var testingOverride: Bool?
    #endif

    /// Master toggle, read from the `WPEOracleEnabled` user default.
    static var isEnabled: Bool {
        #if DEBUG
        if let testingOverride { return testingOverride }
        // Under a test host only `testingOverride` counts: a developer's persisted
        // WPEOracleEnabled=1 otherwise leaks into the suite and freezes the clock /
        // seeds RNG inside unrelated renderer tests (a busy-wait-on-Date.now script
        // test livelocked on exactly this).
        if isRunningInTestHost { return false }
        return UserDefaults.standard.bool(forKey: "WPEOracleEnabled")
        #else
        return false
        #endif
    }

    #if DEBUG
    private static let isRunningInTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    #endif

    /// Opt-in per-pass output hashing (`WPEOraclePerPassHashes`, default OFF). Capturing
    /// + reading back + hashing EVERY scene pass (dozens of up-to-4K textures) is the
    /// dominant oracle capture cost — ~100s on a heavy HDR scene. The self-oracle's
    /// determinism gate only needs the FINAL frame hash (one read-back), so per-pass
    /// hashing stays off by default and is enabled only to LOCATE a divergence during an
    /// actual refactor. Off ⇒ oracle captures fast (final hash + trace structure only).
    static var perPassHashesEnabled: Bool {
        #if DEBUG
        return isEnabled && UserDefaults.standard.bool(forKey: "WPEOraclePerPassHashes")
        #else
        return false
        #endif
    }

    /// Synthetic scene time (seconds) the self-oracle freezes every frame to, so
    /// wall-clock never enters the trace. Defaults to 6.0s — long enough for intros
    /// and particle systems to reach steady state. Overridable via `WPEOracleFreezeTime`.
    static var freezeTime: Double {
        #if DEBUG
        if let value = UserDefaults.standard.object(forKey: "WPEOracleFreezeTime") as? Double, value >= 0 {
            return value
        }
        #endif
        return 6.0
    }

    /// Wall-clock instant the oracle freezes the SCRIPT runtime + text-content
    /// pipeline to. `loadFrameOverride` already freezes the engine's *scene* clock
    /// and time-of-day, but Clock/Date TEXT scripts read the real *wall* clock via
    /// JS `new Date()` / `Date.now()` (e.g. 三体 3509243656, 野火 3460973721, 凯尔希
    /// 3462491575) — a capture straddling a minute boundary hashed differently.
    /// Built in the local calendar so the rendered clock reads 10:09:08 on any
    /// machine; the absolute instant is stable per process ⇒ two runs hash
    /// identically. Inert in Release/Lite (every reader is gated on `isEnabled`).
    static let frozenWallClock: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 1; comps.day = 6
        comps.hour = 10; comps.minute = 9; comps.second = 8
        return Calendar.current.date(from: comps) ?? Date(timeIntervalSince1970: 1_767_694_148)
    }()

    /// `frozenWallClock` as JS epoch milliseconds, for freezing `Date.now()` /
    /// `new Date()` inside script contexts.
    static var frozenWallClockMillis: Double { frozenWallClock.timeIntervalSince1970 * 1000 }

    /// The frozen per-frame inputs an oracle run substitutes for wall-clock time,
    /// time-of-day, and the live cursor, so the trace never captures ambient state.
    /// `nil` in production ⇒ the real frame clock and pointer are used unchanged.
    ///
    /// **self** mode uses the synthetic defaults below. **fidelity** mode replays a
    /// Windows capture: `oracle.py` writes the `WPEOracleReplay*` defaults from
    /// `extract_replay.py`'s `replay.json` so the Mac renders at the SAME frame
    /// globals as the RenderDoc frame — no Swift change needed to consume a replay.
    static func loadFrameOverride() -> WPEOracleFrameOverride? {
        guard isEnabled else { return nil }
        let defaults = UserDefaults.standard
        let time = (defaults.object(forKey: "WPEOracleReplayTime") as? Double) ?? freezeTime
        let daytime = (defaults.object(forKey: "WPEOracleReplayDaytime") as? Double) ?? 0.5
        let pointerX = (defaults.object(forKey: "WPEOracleReplayPointerX") as? Double) ?? 0.5
        let pointerY = (defaults.object(forKey: "WPEOracleReplayPointerY") as? Double) ?? 0.5
        return WPEOracleFrameOverride(
            time: time,
            daytime: min(max(daytime, 0), 1),
            pointer: SIMD2<Double>(pointerX, pointerY)
        )
    }
}

/// Frozen frame globals for a render-oracle capture. Substituted into
/// `WPEMetalRuntimeUniforms` at the top of each frame; see `WPEOracleMode`.
struct WPEOracleFrameOverride: Equatable {
    var time: Double
    var daytime: Double
    var pointer: SIMD2<Double>
}
#endif
