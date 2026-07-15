import Foundation
import Testing
@testable import LiveWallpaper

/// ADR-003 step 1 moved the scene-script tick off the frame path. It bought real
/// throughput (dual display 20→60fps) but the SEMANTICS were never verified, and
/// WPE's contract is that `update()` runs once per frame. Scripts that read the
/// clock (`value = f(time)`) survive any tick rate; scripts that ACCUMULATE
/// (`value.y += k`) encode the frame as their time step, so a dropped tick is a
/// permanently lost increment — 3509243656's universe spin already cost us 57.3x
/// on exactly this kind of arithmetic.
///
/// The oracle cannot see this: capture only renders `load()`'s first frame, and
/// `seedSceneScriptsAfterLoad()` deliberately runs one synchronous tick so frame
/// 1 matches legacy by construction. The divergence starts at frame 2.
///
/// So these tests drive the script instances directly for many frames and count
/// `update()` invocations through `shared` — a side channel the frame path never
/// touches, so counting never perturbs the thing being counted (draining via
/// `liveTick` would itself schedule another tick).
@MainActor
struct WPEScriptAsyncTickSemanticsTests {

    // MARK: - Instrumentation

    /// `shared.n` round-trips as a primitive (the fast path in the shared-state
    /// Proxy), so JS increments land in the host store synchronously on the
    /// engine queue and Swift can read the count without ticking.
    private static let counterPreamble = "shared.n = (shared.n || 0) + 1;"

    private static func updateCount(_ shared: WPESharedScriptState) -> Int {
        Int((shared.get("n") as? Double) ?? 0)
    }

    /// JS busy-loop; makes one `update()` cost more than a frame interval.
    private static func busyLoop(millis: Int) -> String {
        "var __t0 = Date.now(); while (Date.now() - __t0 < \(millis)) {}"
    }

    private static func waitForUpdateCount(
        _ shared: WPESharedScriptState,
        atLeast target: Int,
        timeout: Duration = .seconds(10)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if updateCount(shared) >= target { return true }
            try await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    /// Lets the last in-flight tick land, then confirms the count has stopped
    /// moving — so a burst's total is read after quiescence, not mid-flight.
    private static func quiesce(_ shared: WPESharedScriptState) async throws -> Int {
        var last = updateCount(shared)
        while true {
            try await Task.sleep(for: .milliseconds(120))
            let now = updateCount(shared)
            if now == last { return now }
            last = now
        }
    }

    // MARK: - Lockstep: does async drop a tick even when it keeps up?

    @Test("Lockstep text script: async applies exactly one update() per frame, same values as legacy")
    func textLockstepMatchesLegacyPerFrame() async throws {
        let frames = 24
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            return String(Number(value) + 1);
        }
        """

        // Legacy: the frame path waits, so frame k shows the k-th accumulation.
        let legacyShared = WPESharedScriptState()
        let legacy = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: legacyShared
        )
        var legacyValues: [String] = []
        for _ in 1...frames { legacyValues.append(legacy.tickString()) }
        #expect(legacyValues == (1...frames).map(String.init))
        #expect(Self.updateCount(legacyShared) == frames)

        // Async, lockstep: every frame waits for its tick to actually land, so
        // the engine can never fall behind. This isolates "does the design drop
        // a tick" from "does it drop ticks under load" (measured separately).
        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: asyncShared
        )
        // The load path seeds one synchronous tick so frame 1 isn't a placeholder.
        asyncInstance.seedAsyncTick()

        var asyncValues: [String] = []
        for frame in 1...frames {
            // Drains the previous tick's outcome and schedules the next one.
            asyncValues.append(asyncInstance.liveTickString())
            #expect(try await Self.waitForUpdateCount(asyncShared, atLeast: frame + 1))
        }

        #expect(asyncValues == legacyValues)
        #expect(asyncValues.last == String(frames))
    }

    @Test("Lockstep transform script: async accumulates once per frame, same values as legacy")
    func transformLockstepMatchesLegacyPerFrame() async throws {
        let frames = 24
        let pointer = SIMD2<Double>(0.5, 0.5)
        // The `value.y += k` shape that drifts when a tick is lost.
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            value.y = value.y + 1;
            return value;
        }
        """

        let legacyShared = WPESharedScriptState()
        let legacy = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 100),
            shared: legacyShared
        )
        var legacyY: [Double] = []
        for _ in 1...frames { legacyY.append(try #require(legacy.tick(pointerPosition: pointer)).y) }
        #expect(legacyY == (1...frames).map(Double.init))

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPEDynamicTransformScriptInstance(
            script: script,
            seed: SIMD3<Double>(0, 0, 0),
            canvasSize: SIMD2<Double>(100, 100),
            shared: asyncShared
        )
        asyncInstance.seedAsyncTick(pointerPosition: pointer)

        var asyncY: [Double] = []
        for frame in 1...frames {
            asyncY.append(try #require(asyncInstance.liveTick(pointerPosition: pointer)).y)
            #expect(try await Self.waitForUpdateCount(asyncShared, atLeast: frame + 1))
        }

        #expect(asyncY == legacyY)
        #expect(asyncY.last == Double(frames))
    }

    @Test("Lockstep layer script: async accumulates once per frame, same values as legacy")
    func layerLockstepMatchesLegacyPerFrame() async throws {
        let frames = 24
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            return value + 1;
        }
        """

        let legacyShared = WPESharedScriptState()
        let legacy = try WPELayerScriptInstance(
            script: script,
            shared: legacyShared,
            outputMode: .returnedAlpha(initialValue: 0)
        )
        var legacyAlpha: [Double] = []
        for _ in 1...frames { legacyAlpha.append(try #require(legacy.tick(runtimeSeconds: 1)?.own.alpha)) }
        #expect(legacyAlpha == (1...frames).map(Double.init))

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPELayerScriptInstance(
            script: script,
            shared: asyncShared,
            outputMode: .returnedAlpha(initialValue: 0)
        )
        // Mirrors seedSceneScriptsAfterLoad: layer hosts seed with a bounded
        // SYNCHRONOUS tick whose output the renderer applies directly (it never
        // reaches the async slot), so frame 1's liveTick drains nil = keep-last.
        var applied = try #require(asyncInstance.tick(runtimeSeconds: 1)?.own.alpha)

        var asyncAlpha: [Double] = []
        for frame in 1...frames {
            if let fresh = asyncInstance.liveTick(runtimeSeconds: 1)?.own.alpha { applied = fresh }
            asyncAlpha.append(applied)
            #expect(try await Self.waitForUpdateCount(asyncShared, atLeast: frame + 1))
        }

        #expect(asyncAlpha == legacyAlpha)
        #expect(asyncAlpha.last == Double(frames))
    }

    // MARK: - Contention: the frame path outruns the engine

    /// The decisive measurement. `WPESceneScriptOutcomeSlot.beginTick()` allows
    /// ONE tick in flight; a frame that finds one running schedules nothing and
    /// that frame contributes no `update()`. So when the frame path outruns the
    /// engine, `update()` count < frame count — permanently, silently.
    ///
    /// Measured 2026-07-15: 1 update() for 40 back-to-back frames (20ms tick).
    /// Deleting the `beginTick()` back-pressure makes it 40/40, which is how we
    /// know the claim — not the queue, not the clock — is what drops the ticks.
    @Test("Frames outrunning the engine: async swallows ticks, legacy does not")
    func asyncSwallowsTicksWhenFramesOutrunEngine() async throws {
        let frames = 40
        let busyMillis = 20
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            \(Self.busyLoop(millis: busyMillis))
            return String(Number(value) + 1);
        }
        """

        // Legacy blocks the frame path, so every frame gets its update().
        let legacyShared = WPESharedScriptState()
        let legacy = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: legacyShared,
            tickBudget: 5
        )
        for _ in 1...frames { _ = legacy.tickString() }
        #expect(Self.updateCount(legacyShared) == frames)
        #expect(legacy.lastValue == String(frames))

        // Async: frames issued back-to-back — the pathological end of the same
        // spectrum a 60fps frame path sits on whenever a tick exceeds 16.7ms.
        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: asyncShared,
            tickBudget: 5
        )
        for _ in 1...frames { _ = asyncInstance.liveTickString() }
        let asyncUpdates = try await Self.quiesce(asyncShared)

        // Characterization of a REAL defect, not a blessing of it: async mode is
        // default-ON, so accumulating scripts are drifting in shipped builds.
        // If a fix lands making this once-per-frame, this assertion SHOULD fail.
        #expect(asyncUpdates < frames)
        #expect(asyncUpdates <= 5, "expected near-total tick loss in a tight burst, got \(asyncUpdates)/\(frames)")
    }

    /// Quantifies the loss at a realistic cadence: a tick costing more than a
    /// frame interval loses roughly `1 - frameInterval/tickCost` of its updates.
    /// Measured 2026-07-15: 15 update() calls for 30 frames — an accumulating
    /// script advances at HALF speed, and the factor moves with machine load.
    @Test("60fps cadence with a 30ms tick: async loses roughly half its update() calls")
    func asyncLossRateAtSixtyFpsWithSlowTick() async throws {
        let frames = 30
        let busyMillis = 30
        let frameInterval = Duration.microseconds(16_667)
        let script = """
        export function update(value) {
            \(Self.counterPreamble)
            \(Self.busyLoop(millis: busyMillis))
            return String(Number(value) + 1);
        }
        """

        let shared = WPESharedScriptState()
        let instance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: shared,
            tickBudget: 5
        )

        let clock = ContinuousClock()
        var deadline = clock.now
        for _ in 1...frames {
            _ = instance.liveTickString()
            deadline += frameInterval
            try await Task.sleep(until: deadline, clock: clock)
        }
        let updates = try await Self.quiesce(shared)

        // ~16.7ms per frame vs ~30ms per tick → at most ~4/7 of the frames can
        // start a tick. Bounded loosely on both sides: the point is that the
        // accumulation rate tracks the ENGINE, not the frame clock.
        #expect(updates < frames)
        #expect(updates <= (frames * 3) / 4, "expected substantial tick loss, got \(updates)/\(frames)")
        #expect(updates >= 2, "sanity: the engine must have ticked at all, got \(updates)")
    }
}
