import Foundation
import Testing
@testable import LiveWallpaper

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [Int] = []
    private var threads: [ObjectIdentifier] = []

    func record(index: Int) {
        lock.lock()
        defer { lock.unlock() }
        order.append(index)
        threads.append(ObjectIdentifier(Thread.current))
    }

    var recordedOrder: [Int] { lock.lock(); defer { lock.unlock() }; return order }
    var distinctThreads: Set<ObjectIdentifier> { lock.lock(); defer { lock.unlock() }; return Set(threads) }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class OverlapDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private var overlapped = false
    func enter() { lock.lock(); inside += 1; if inside > 1 { overlapped = true }; lock.unlock() }
    func leave() { lock.lock(); inside -= 1; lock.unlock() }
    var overlapDetected: Bool { lock.lock(); defer { lock.unlock() }; return overlapped }
}

struct WPERenderThreadTests {

    @Test("perform runs work serially, FIFO, all on the one render thread")
    func serialFIFOSingleThread() {
        let thread = WPERenderThread(label: "test.serial")
        defer { thread.shutdown() }

        let recorder = Recorder()
        let done = DispatchSemaphore(value: 0)
        let n = 200

        for i in 0..<n {
            thread.perform { recorder.record(index: i) }
        }
        thread.perform { done.signal() }
        #expect(done.wait(timeout: .now() + 5) == .success)

        #expect(recorder.recordedOrder == Array(0..<n))
        #expect(recorder.distinctThreads.count == 1)
        #expect(!recorder.distinctThreads.contains(ObjectIdentifier(Thread.current)))
    }

    @Test("isCurrent is true only while executing on the render thread")
    func isCurrentReflectsThread() {
        let thread = WPERenderThread(label: "test.iscurrent")
        defer { thread.shutdown() }

        #expect(thread.isCurrent == false)

        let box = Counter()
        let done = DispatchSemaphore(value: 0)
        thread.perform {
            if thread.isCurrent { box.increment() }
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(box.count == 1)
    }

    @Test("a Timer added to the render loop fires (run loop stays alive)")
    func timerFires() {
        let thread = WPERenderThread(label: "test.timer")
        defer { thread.shutdown() }

        let fired = DispatchSemaphore(value: 0)
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in fired.signal() }
        thread.add(timer)

        #expect(fired.wait(timeout: .now() + 5) == .success)
    }

    @Test("shutdown drains queued work, is idempotent, and still consumes later work")
    func shutdownDrainsAndIdempotent() {
        let thread = WPERenderThread(label: "test.shutdown")

        let counter = Counter()
        let n = 100
        for _ in 0..<n {
            thread.perform { counter.increment() }
        }
        thread.shutdown()
        #expect(counter.count == n)

        thread.perform { counter.increment() }
        #expect(counter.count == n + 1)

        thread.shutdown()
        #expect(counter.count == n + 1)
    }

    @Test("shutdown window: a post-shutdown job never overlaps an in-flight render-thread job")
    func shutdownWindowMutualExclusion() {
        let thread = WPERenderThread(label: "test.shutdown.window")
        let overlap = OverlapDetector()

        let aRunning = DispatchSemaphore(value: 0)
        let aMayFinish = DispatchSemaphore(value: 0)
        let bDone = DispatchSemaphore(value: 0)
        let shutdownReturned = DispatchSemaphore(value: 0)

        thread.perform {
            overlap.enter()
            aRunning.signal()
            aMayFinish.wait()
            overlap.leave()
        }
        #expect(aRunning.wait(timeout: .now() + 5) == .success)

        Thread.detachNewThread {
            thread.shutdown()
            shutdownReturned.signal()
        }
        Thread.sleep(forTimeInterval: 0.1)

        Thread.detachNewThread {
            thread.perform {
                overlap.enter()
                overlap.leave()
                bDone.signal()
            }
        }
        Thread.sleep(forTimeInterval: 0.1)

        aMayFinish.signal()
        #expect(bDone.wait(timeout: .now() + 5) == .success)
        #expect(shutdownReturned.wait(timeout: .now() + 5) == .success)
        #expect(overlap.overlapDetected == false)
    }

    @Test("checkIsolated passes on the render thread (bare callback, no task executor)")
    func executorCheckIsolatedOnThread() {
        let thread = WPERenderThread(label: "test.checkisolated")
        defer { thread.shutdown() }
        let executor = WPERenderThreadExecutor(thread: thread)

        let passed = Counter()
        let done = DispatchSemaphore(value: 0)
        thread.perform {
            executor.checkIsolated()
            passed.increment()
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(passed.count == 1)
    }

    @Test("adaptive QoS actually re-tiers the OS thread: economy → high → economy")
    func adaptiveQoSChangesRealThreadClass() {
        let thread = WPERenderThread(label: "test.qos.adaptive", adaptiveQoSEnabled: true)
        defer { thread.shutdown() }

        func qosAfter(feeding durations: [Double]) -> qos_class_t {
            let box = QoSBox()
            let done = DispatchSemaphore(value: 0)
            thread.perform {
                for d in durations { thread.noteFrameDuration(d) }
                box.value = qos_class_self()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
            return box.value
        }

        #expect(qosAfter(feeding: Array(repeating: 0.012, count: 5)) == QOS_CLASS_USER_INTERACTIVE)
        #expect(qosAfter(feeding: Array(repeating: 0.002, count: 120)) == QOS_CLASS_UTILITY)
    }

    @Test("escape hatch OFF keeps the OS thread at userInteractive despite cheap frames")
    func disabledEscapeHatchKeepsRealThreadHigh() {
        let thread = WPERenderThread(label: "test.qos.pinned", adaptiveQoSEnabled: false)
        defer { thread.shutdown() }

        let box = QoSBox()
        let done = DispatchSemaphore(value: 0)
        thread.perform {
            for _ in 0..<120 { thread.noteFrameDuration(0.001) }
            box.value = qos_class_self()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        #expect(box.value == QOS_CLASS_USER_INTERACTIVE)
    }
}

private final class QoSBox: @unchecked Sendable {
    var value: qos_class_t = QOS_CLASS_UNSPECIFIED
}

struct WPEAdaptiveRenderQoSTests {

    @Test("disabled escape hatch pins .high and never downgrades")
    func disabledPinsHigh() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: false)
        #expect(qos.level == .high)
        for _ in 0..<200 {
            #expect(qos.record(frameDuration: 0.0005) == nil)
        }
        #expect(qos.level == .high)
    }

    @Test("enabled starts economy and climbs to high once p95 exceeds the raise threshold")
    func raiseOnOverrun() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        #expect(qos.level == .economy)
        #expect(qos.record(frameDuration: 0.012) == .high)
        #expect(qos.level == .high)
    }

    @Test("hysteresis: mid-band durations neither raise from economy nor lower from high")
    func hysteresisDeadZone() {
        var fromEconomy = WPEAdaptiveRenderQoS(isEnabled: true)
        for _ in 0..<120 { #expect(fromEconomy.record(frameDuration: 0.008) == nil) }
        #expect(fromEconomy.level == .economy)

        var fromHigh = WPEAdaptiveRenderQoS(isEnabled: true)
        _ = fromHigh.record(frameDuration: 0.012)
        #expect(fromHigh.level == .high)
        for _ in 0..<120 { #expect(fromHigh.record(frameDuration: 0.008) == nil) }
        #expect(fromHigh.level == .high)
    }

    @Test("high downgrades to economy once the whole window is comfortably under budget")
    func lowerWhenComfortable() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        _ = qos.record(frameDuration: 0.012)
        #expect(qos.level == .high)
        var downgraded = false
        for _ in 0..<90 where !downgraded {
            if qos.record(frameDuration: 0.003) == .economy { downgraded = true }
        }
        #expect(downgraded)
        #expect(qos.level == .economy)
    }

    @Test("warm-up boost pins high for exactly N frames regardless of cheap timings")
    func boostPinsThenReleases() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        qos.boost(frames: 3)
        #expect(qos.record(frameDuration: 0.001) == .high)
        #expect(qos.record(frameDuration: 0.001) == nil)
        #expect(qos.record(frameDuration: 0.001) == nil)
        #expect(qos.level == .high)
        #expect(qos.boostFramesRemainingForTesting == 0)
        var back = false
        for _ in 0..<90 where !back {
            if qos.record(frameDuration: 0.001) == .economy { back = true }
        }
        #expect(back)
    }

    @Test("budget retarget: a 30fps budget tolerates frames a 60fps budget would reject")
    func budgetRetarget() {
        var qos = WPEAdaptiveRenderQoS(isEnabled: true)
        qos.setBudget(seconds: 1.0 / 30.0)
        for _ in 0..<120 { #expect(qos.record(frameDuration: 0.012) == nil) }
        #expect(qos.level == .economy)
    }
}

struct WPEDisplayRenderActorTests {

    @Test("run() hops onto the render thread and isolation is bound to the executor")
    func runExecutesOnRenderThread() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.run")
        defer { actor.shutdown() }

        #expect(actor.isOnRenderThread == false)

        let onRenderThread = await actor.run { iso in iso.isOnRenderThread }
        #expect(onRenderThread == true)
    }

    @Test("successive run() calls land on the same render thread")
    func runIsStableThread() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.stable")
        defer { actor.shutdown() }

        let a = await actor.run { _ in ObjectIdentifier(Thread.current) }
        let b = await actor.run { _ in ObjectIdentifier(Thread.current) }
        #expect(a == b)
        let onMain = await actor.run { _ in Thread.isMainThread }
        #expect(onMain == false)
    }

    @Test("assumeIsolatedOnRenderThread grants sync isolated access from a bare run-loop callback")
    func assumeIsolatedSyncEntry() {
        let actor = WPEDisplayRenderActor(label: "test.actor.assume")
        defer { actor.shutdown() }

        let box = Counter()
        let done = DispatchSemaphore(value: 0)
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            let onThread = actor.assumeIsolatedOnRenderThread { iso in iso.isOnRenderThread }
            if onThread { box.increment() }
            done.signal()
        }
        actor.add(timer)

        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(box.count == 1)
    }

    @Test("actor work after shutdown is still consumed, not dropped")
    func jobConsumedAfterShutdown() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.postshutdown")
        actor.shutdown()

        let value = await actor.run { _ in 42 }
        #expect(value == 42)
    }

    // MARK: - Main-backed (M2c1 flag-off) mode

    @Test("main-backed actor runs isolation on the main thread, not a render thread")
    @MainActor
    func mainBackingRunsOnMain() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.main", backing: .main)
        defer { actor.shutdown() }

        let onMain = await actor.run { _ in Thread.isMainThread }
        #expect(onMain == true)
        let onRenderThread = await actor.run { iso in iso.isOnRenderThread }
        #expect(onRenderThread == true)
    }

    @Test("main-backed actor owns no thread and shutdown is a no-op")
    @MainActor
    func mainBackingShutdownIsNoOp() async {
        let actor = WPEDisplayRenderActor(label: "test.actor.main.shutdown", backing: .main)
        actor.shutdown()
        let value = await actor.run { _ in 7 }
        #expect(value == 7)
    }

#if !LITE_BUILD
    @Test("main-backed shim renders the frame synchronously (draw returns = frame produced)")
    @MainActor
    func mainBackedShimRendersSynchronously() {
        let actor = WPEDisplayRenderActor(backing: .main)
        defer { actor.shutdown() }
        let shim = WPERenderSurfaceClientShim(renderActor: actor, backing: .main)

        #expect(shim.completedFrameDeliveries == 0)
        shim.renderAndPresentFrame()
        #expect(shim.completedFrameDeliveries == 1)
        shim.renderAndPresentFrame()
        #expect(shim.completedFrameDeliveries == 2)
    }

    @Test("render-thread-backed shim delivers the frame asynchronously")
    @MainActor
    func renderThreadShimDeliversAsynchronously() async {
        let actor = WPEDisplayRenderActor(backing: .renderThread)
        defer { actor.shutdown() }
        let shim = WPERenderSurfaceClientShim(renderActor: actor, backing: .renderThread)

        shim.renderAndPresentFrame()
        var delivered = false
        for _ in 0..<400 where !delivered {
            if shim.completedFrameDeliveries == 1 { delivered = true; break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(delivered)
    }
#endif

    @Test("off-main render flag defaults to true (render-thread backing)")
    func offMainFlagDefaultsTrue() {
        UserDefaults.standard.removeObject(forKey: WPEOffMainRenderFlag.defaultsKey)
        #expect(WPEOffMainRenderFlag.isEnabled == true)
        if case .renderThread = WPEOffMainRenderFlag.backing {} else {
            Issue.record("absent flag must select .renderThread backing")
        }
    }

    @Test("writing the flag false rolls back to main backing")
    func offMainFlagFalseSelectsMain() {
        UserDefaults.standard.set(false, forKey: WPEOffMainRenderFlag.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: WPEOffMainRenderFlag.defaultsKey) }
        #expect(WPEOffMainRenderFlag.isEnabled == false)
        if case .main = WPEOffMainRenderFlag.backing {} else {
            Issue.record("flag written false must select .main backing")
        }
    }

    @Test("M2c1b-3c: flag-on selects the dedicated render-thread backing")
    func offMainFlagSelectsRenderThread() {
        UserDefaults.standard.set(true, forKey: WPEOffMainRenderFlag.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: WPEOffMainRenderFlag.defaultsKey) }
        #expect(WPEOffMainRenderFlag.isEnabled == true)
        if case .renderThread = WPEOffMainRenderFlag.backing {} else {
            Issue.record("flag-on must select .renderThread backing after b-3c")
        }
    }

#if !LITE_BUILD
    // MARK: - M2c2 CADisplayLink frame driver

    @Test("effectiveFPS maps to a fixed-cadence frame-rate range (min == max == preferred)")
    func fpsMapsToFrameRateRange() {
        let range = WPEDisplayRenderActor.frameRateRange(forPreferredFPS: 30)
        #expect(range.minimum == 30)
        #expect(range.maximum == 30)
        #expect(range.preferred == 30)
        let clamped = WPEDisplayRenderActor.frameRateRange(forPreferredFPS: 0)
        #expect(clamped.maximum == 1)
    }

    @Test("link pacing setters buffer pause + fps on the render thread even with no link installed")
    func linkPacingBuffers() async {
        let actor = WPEDisplayRenderActor(label: "test.link.buffer", backing: .renderThread)
        defer { actor.shutdown() }

        await actor.run { iso in
            iso.setLinkPaused(false)
            iso.setLinkPreferredFPS(24)
        }
        let (paused, fps, hasLink) = await actor.run { iso in
            (iso.linkPausedForTesting, iso.linkPreferredFPSForTesting, iso.hasDisplayLinkForTesting)
        }
        #expect(paused == false)
        #expect(fps == 24)
        #expect(hasLink == false)
    }

    @Test("the pacer routes applyPacing onto the render-thread link buffer")
    func pacerRoutesPacingToLink() async {
        let actor = WPEDisplayRenderActor(label: "test.link.pacer", backing: .renderThread)
        defer { actor.shutdown() }
        let pacer = WPERenderThreadFramePacer(surface: StubSurfaceControl(), renderActor: actor)

        await actor.run { _ in
            pacer.applyPacing(WPERenderPacingUpdate(
                isPaused: false,
                enableSetNeedsDisplay: nil,
                preferredFramesPerSecond: 48
            ))
        }
        let (paused, fps) = await actor.run { iso in
            (iso.linkPausedForTesting, iso.linkPreferredFPSForTesting)
        }
        #expect(paused == false)
        #expect(fps == 48)
    }

    @Test("a run-loop callback drives renderFrame on the render thread (link stand-in)")
    func linkCallbackDrivesFrameOnRenderThread() {
        let actor = WPEDisplayRenderActor(label: "test.link.callback", backing: .renderThread)
        defer { actor.shutdown() }

        let onThread = Counter()
        let done = DispatchSemaphore(value: 0)
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            actor.assumeIsolatedOnRenderThread { iso in
                if iso.isOnRenderThread { onThread.increment() }
                iso.renderFrame()
            }
            done.signal()
        }
        actor.add(timer)

        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(onThread.count == 1)
    }
#endif
}

#if !LITE_BUILD
private final class StubSurfaceControl: WPESurfaceControl, @unchecked Sendable {
    func applyPacing(_ update: WPERenderPacingUpdate) {}
    func setNeedsRedraw() {}
    func drawImmediately() {}
    func releaseDrawables() {}
    func detach() {}
    func setClickCaptureEnabled(_ enabled: Bool) {}
}
#endif
