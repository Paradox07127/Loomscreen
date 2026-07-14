import Testing
@testable import LiveWallpaper

@Suite("HTML reload scheduler lifecycle")
@MainActor
struct HTMLReloadSchedulerTests {
    @Test("Suspend cancels refresh and retry tasks; resume restarts both")
    func suspendAndResumeRestartFromNow() {
        let scheduler = HTMLReloadScheduler(reload: {}) { $0 }
        scheduler.setRefreshInterval(seconds: 3_600)
        scheduler.scheduleRetry(after: 3_600)

        #expect(scheduler.hasScheduledRefresh)
        #expect(scheduler.hasScheduledRetry)

        scheduler.setSuspended(true)

        #expect(!scheduler.hasScheduledRefresh)
        #expect(!scheduler.hasScheduledRetry)
        #expect(scheduler.hasPendingRetry)

        scheduler.setSuspended(false)

        #expect(scheduler.hasScheduledRefresh)
        #expect(scheduler.hasScheduledRetry)
        scheduler.invalidate()
    }

    @Test("Changing refresh while suspended waits until resume")
    func refreshConfiguredWhileSuspendedDoesNotStartEarly() {
        let scheduler = HTMLReloadScheduler(reload: {}) { $0 }
        scheduler.setSuspended(true)
        scheduler.setRefreshInterval(seconds: 60)

        #expect(!scheduler.hasScheduledRefresh)

        scheduler.setSuspended(false)

        #expect(scheduler.hasScheduledRefresh)
        scheduler.invalidate()
    }

    @Test("Cancelled retry is not resurrected by resume")
    func cancelledRetryStaysCancelled() {
        let scheduler = HTMLReloadScheduler(reload: {}) { $0 }
        scheduler.scheduleRetry(after: 3_600)
        scheduler.setSuspended(true)
        scheduler.cancelRetry()
        scheduler.setSuspended(false)

        #expect(!scheduler.hasPendingRetry)
        #expect(!scheduler.hasScheduledRetry)
        scheduler.invalidate()
    }

    @Test("Suspended intervals do not reload or catch up on resume")
    func suspendedIntervalsDoNotCatchUp() async throws {
        var reloadCount = 0
        let scheduler = HTMLReloadScheduler(
            reload: { reloadCount += 1 },
            jitteredInterval: { $0 }
        )
        scheduler.setRefreshInterval(seconds: 0.02)
        scheduler.setSuspended(true)

        try await Task.sleep(for: .milliseconds(70))
        #expect(reloadCount == 0)

        scheduler.setSuspended(false)
        try await Task.sleep(for: .milliseconds(5))
        #expect(reloadCount == 0)

        try await Task.sleep(for: .milliseconds(25))
        #expect(reloadCount == 1)
        scheduler.invalidate()
    }
}
