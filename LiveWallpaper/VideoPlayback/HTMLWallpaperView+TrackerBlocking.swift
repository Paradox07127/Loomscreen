import LiveWallpaperCore
import WebKit

extension HTMLWallpaperView {
    // MARK: - Tracker Blocking

    /// App 启动时调用一次：把 tracker 规则编译进 `WKContentRuleListStore`， 后续每个实例直接 `lookUp`，省去 50–200ms 的同步编译。
    static func precompileTrackerRules() {
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: trackerRuleListIdentifier,
            encodedContentRuleList: trackerRuleListJSON
        ) { _, error in
            if let error {
                Logger.warning(
                    "Tracker rule list precompile failed: \(error.localizedDescription)",
                    category: .screenManager
                )
            }
        }
    }

    func applyTrackerBlocking(enabled: Bool) {
        trackerBlockingRequested = enabled
        let controller = webView.configuration.userContentController
        if !enabled {
            if let existing = compiledTrackerRuleList, hasTrackerRulesAttached {
                controller.remove(existing)
                hasTrackerRulesAttached = false
            }
            return
        }
        if let cached = compiledTrackerRuleList {
            if !hasTrackerRulesAttached {
                controller.add(cached)
                hasTrackerRulesAttached = true
            }
            return
        }
        WKContentRuleListStore.default()?.lookUpContentRuleList(
            forIdentifier: HTMLWallpaperView.trackerRuleListIdentifier
        ) { [weak self] list, _ in
            Task { @MainActor [weak self] in
                guard let self, self.trackerBlockingRequested else { return }
                if let list {
                    self.attachTrackerList(list)
                } else {
                    self.compileAndAttachTrackerList()
                }
            }
        }
    }

    private func compileAndAttachTrackerList() {
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: HTMLWallpaperView.trackerRuleListIdentifier,
            encodedContentRuleList: HTMLWallpaperView.trackerRuleListJSON
        ) { [weak self] list, error in
            Task { @MainActor [weak self] in
                guard let self, self.trackerBlockingRequested else { return }
                if let error {
                    Logger.warning(
                        "Tracker rule list compile failed: \(error.localizedDescription)",
                        category: .screenManager
                    )
                }
                guard let list else { return }
                self.attachTrackerList(list)
            }
        }
    }

    private func attachTrackerList(_ list: WKContentRuleList) {
        compiledTrackerRuleList = list
        guard !hasTrackerRulesAttached else { return }
        webView.configuration.userContentController.add(list)
        hasTrackerRulesAttached = true
    }

    // MARK: - Tracker Rule List

    private static let trackerRuleListIdentifier = "LiveWallpaper.HTMLWallpaper.TrackerRules.v1"

    /// Common analytics/ad hosts blocked before the renderer sees them.
    private static let trackerRuleListJSON = """
    [
      {
        "trigger": {
          "url-filter": ".*",
          "if-domain": [
            "*google-analytics.com",
            "*googletagmanager.com",
            "*doubleclick.net",
            "*facebook.net",
            "*scorecardresearch.com",
            "*hotjar.com",
            "*mixpanel.com",
            "*segment.com",
            "*segment.io",
            "*amplitude.com",
            "*fullstory.com",
            "*adservice.google.com",
            "*adsystem.com"
          ]
        },
        "action": { "type": "block" }
      }
    ]
    """
}
