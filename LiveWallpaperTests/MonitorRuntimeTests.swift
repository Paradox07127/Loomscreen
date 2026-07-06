import Testing
import Foundation
@testable import LiveWallpaper

@Suite("Monitor runtime leases")
struct MonitorRuntimeTests {
    private var quietOptions: MonitorRuntimeOptions {
        // system:false keeps tests free of real samplers; no factories fire
        // because agents/usage stay false.
        MonitorRuntimeOptions(system: false)
    }

    @Test("Release arriving before its acquire cancels the late acquire")
    func releaseBeforeAcquire() async {
        let runtime = MonitorRuntime()
        let lease = UUID()

        await runtime.release(leaseID: lease)
        await runtime.acquire(leaseID: lease, options: quietOptions)

        #expect(await runtime.debugActiveLeaseCount == 0)
    }

    @Test("Balanced acquire then release ends with no live leases")
    func balancedLifecycle() async {
        let runtime = MonitorRuntime()
        let lease = UUID()

        await runtime.acquire(leaseID: lease, options: quietOptions)
        #expect(await runtime.debugActiveLeaseCount == 1)

        await runtime.release(leaseID: lease)
        #expect(await runtime.debugActiveLeaseCount == 0)
    }

    @Test("Pipeline options are the union across all live leases")
    func mergedOptionsUnion() {
        var systemOnly = MonitorRuntimeOptions(system: true)
        systemOnly.topProcesses = true
        var agentsOnly = MonitorRuntimeOptions(system: false)
        agentsOnly.agents = true
        agentsOnly.usage = true
        agentsOnly.claudeRoot = URL(fileURLWithPath: "/tmp/claude")

        let merged = MonitorRuntime.merged([systemOnly, agentsOnly])

        #expect(merged?.system == true)
        #expect(merged?.agents == true)
        #expect(merged?.usage == true)
        #expect(merged?.topProcesses == true)
        #expect(merged?.claudeRoot == URL(fileURLWithPath: "/tmp/claude"))
        #expect(MonitorRuntime.merged([]) == nil)
    }

    @Test("Final release clears the broker so stale snapshots can't replay")
    func finalReleaseClearsBroker() async {
        let runtime = MonitorRuntime()
        let lease = UUID()

        await runtime.acquire(leaseID: lease, options: quietOptions)
        runtime.broker.publish(MonitorSnapshot(timestamp: 1))
        #expect(runtime.broker.latest(after: 0) != nil)

        await runtime.release(leaseID: lease)
        #expect(runtime.broker.latest(after: 0) == nil)
    }

    @Test("A second display's differing lease widens, not replaces, the pipeline")
    func secondLeaseWidens() async {
        let runtime = MonitorRuntime()
        let first = UUID()
        let second = UUID()
        var agentLease = quietOptions
        agentLease.agents = true

        await runtime.acquire(leaseID: first, options: quietOptions)
        await runtime.acquire(leaseID: second, options: agentLease)
        #expect(await runtime.debugActiveLeaseCount == 2)

        // Dropping the agent lease narrows back down; dropping both stops all.
        await runtime.release(leaseID: second)
        #expect(await runtime.debugActiveLeaseCount == 1)
        await runtime.release(leaseID: first)
        #expect(await runtime.debugActiveLeaseCount == 0)
    }
}
