import WebKit

extension HTMLWallpaperView {
    /// Returns `true` when a retry was scheduled and the caller should skip `reportError`.
    func shouldRetryNavigationFailure() -> Bool {
        let maxRetries = max(0, lastAppliedConfig?.maxRetries ?? 0)
        guard consecutiveFailureCount < maxRetries else { return false }
        scheduleRetry()
        return true
    }

    private func scheduleRetry() {
        consecutiveFailureCount += 1
        let delaySeconds = pow(2.0, Double(consecutiveFailureCount - 1))
        reloadScheduler.scheduleRetry(after: delaySeconds)
    }

    func resetNavigationFailureState() {
        consecutiveFailureCount = 0
        reloadScheduler.cancelRetry()
    }

    func navigationFailureURL(webView: WKWebView, error: NSError) -> URL {
        if let url = webView.url {
            return url
        }
        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return url
        }
        return URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
    }

    func shouldIgnoreNavigationFailure(_ error: NSError) -> Bool {
        if isCleaningUp { return true }
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
