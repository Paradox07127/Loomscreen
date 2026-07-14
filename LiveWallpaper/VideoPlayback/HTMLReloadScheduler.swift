import Foundation

/// Owns HTML refresh and navigation-retry timing independently from WebKit.
/// Suspending cancels every live task while retaining only the intent needed
/// to restart from the moment of resume; elapsed intervals are never caught up.
@MainActor
final class HTMLReloadScheduler {
    private let reload: @MainActor () -> Void
    private let jitteredInterval: (TimeInterval) -> TimeInterval

    private var refreshInterval: TimeInterval?
    private var pendingRetryDelay: TimeInterval?
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private(set) var isSuspended = false
    private(set) var isInvalidated = false

    var hasScheduledRefresh: Bool { refreshTask != nil }
    var hasScheduledRetry: Bool { retryTask != nil }
    var hasPendingRetry: Bool { pendingRetryDelay != nil }

    init(
        reload: @escaping @MainActor () -> Void,
        jitteredInterval: @escaping (TimeInterval) -> TimeInterval = { base in
            let range = base * 0.1
            return max(1, base + Double.random(in: -range...range))
        }
    ) {
        self.reload = reload
        self.jitteredInterval = jitteredInterval
    }

    func setRefreshInterval(seconds: TimeInterval) {
        refreshInterval = seconds > 0 ? seconds : nil
        cancelRefreshTask()
        startRefreshIfNeeded()
    }

    func scheduleRetry(after delay: TimeInterval) {
        pendingRetryDelay = max(0, delay)
        retryTask?.cancel()
        retryTask = nil
        startRetryIfNeeded()
    }

    func cancelRetry() {
        pendingRetryDelay = nil
        retryTask?.cancel()
        retryTask = nil
    }

    func setSuspended(_ suspended: Bool) {
        guard !isInvalidated, isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            cancelRefreshTask()
            retryTask?.cancel()
            retryTask = nil
        } else {
            startRefreshIfNeeded()
            startRetryIfNeeded()
        }
    }

    func invalidate() {
        isInvalidated = true
        refreshInterval = nil
        pendingRetryDelay = nil
        cancelRefreshTask()
        retryTask?.cancel()
        retryTask = nil
    }

    private func startRefreshIfNeeded() {
        guard !isInvalidated,
              !isSuspended,
              refreshTask == nil,
              refreshInterval != nil else { return }

        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let base = self?.refreshInterval else { return }
                let interval = self?.jitteredInterval(base) ?? base
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      !self.isInvalidated,
                      !self.isSuspended else { return }
                self.reload()
            }
        }
    }

    private func startRetryIfNeeded() {
        guard !isInvalidated,
              !isSuspended,
              retryTask == nil,
              let delay = pendingRetryDelay else { return }

        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  !self.isInvalidated,
                  !self.isSuspended else { return }
            self.pendingRetryDelay = nil
            self.retryTask = nil
            self.reload()
        }
    }

    private func cancelRefreshTask() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
