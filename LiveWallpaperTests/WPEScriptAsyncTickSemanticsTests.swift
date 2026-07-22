import Foundation
import Testing
@testable import LiveWallpaper

@MainActor
struct WPEScriptAsyncTickSemanticsTests {

    // MARK: - Instrumentation

    private static let counterPreamble = "shared.n = (shared.n || 0) + 1;"

    private static func updateCount(_ shared: WPESharedScriptState) -> Int {
        Int((shared.get("n") as? Double) ?? 0)
    }

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

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: asyncShared
        )
        asyncInstance.seedAsyncTick()

        var asyncValues: [String] = []
        for frame in 1...frames {
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

        let asyncShared = WPESharedScriptState()
        let asyncInstance = try WPESceneScriptInstance(
            script: script,
            initialValue: "0",
            shared: asyncShared,
            tickBudget: 5
        )
        for _ in 1...frames { _ = asyncInstance.liveTickString() }
        let asyncUpdates = try await Self.quiesce(asyncShared)

        #expect(asyncUpdates < frames)
        #expect(asyncUpdates <= 5, "expected near-total tick loss in a tight burst, got \(asyncUpdates)/\(frames)")
    }

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

        #expect(updates < frames)
        #expect(updates <= (frames * 3) / 4, "expected substantial tick loss, got \(updates)/\(frames)")
        #expect(updates >= 2, "sanity: the engine must have ticked at all, got \(updates)")
    }
}
