import AppKit
import Combine
import Observation

/// Detects when a full-screen app covers the desktop on each display.
/// Uses CGWindowListCopyWindowInfo (no permission required) + workspace notifications.
@MainActor @Observable
final class FullScreenDetector {

    // MARK: - Observed State

    private(set) var hiddenScreens: [CGDirectDisplayID: Bool] = [:]

    // MARK: - Private Properties

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var pollTimer: AnyCancellable?
    @ObservationIgnored private let pollInterval: TimeInterval

    // MARK: - Initialization

    init(pollInterval: TimeInterval = 30.0) {
        self.pollInterval = pollInterval
        setupNotifications()
        checkFullScreenState()
    }

    // MARK: - Setup

    private func setupNotifications() {
        // React to space changes (includes entering/exiting fullscreen Spaces)
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkFullScreenState() }
            .store(in: &cancellables)

        // React to app activation changes
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkFullScreenState() }
            .store(in: &cancellables)
    }

    var isFallbackPollingEnabled: Bool {
        pollTimer != nil
    }

    func setFallbackPollingEnabled(_ enabled: Bool) {
        if enabled {
            startPollingIfNeeded()
            checkFullScreenState()
        } else {
            stopPolling()
        }
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil else { return }

        pollTimer = Timer.publish(every: pollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkFullScreenState() }
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    func stop() {
        stopPolling()
        cancellables.removeAll()
    }

    // MARK: - Detection via CGWindowListCopyWindowInfo (NO permission required)

    private func checkFullScreenState() {
        var result: [CGDirectDisplayID: Bool] = [:]
        let screens = NSScreen.screens

        // Initialize all screens as not hidden
        for screen in screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                result[id] = false
            }
        }

        // If displays don't have separate spaces, use the simpler presentation options check
        if !NSScreen.screensHaveSeparateSpaces {
            let isFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            for key in result.keys { result[key] = isFullScreen }
            updateIfChanged(result)
            return
        }

        // Per-screen detection via CGWindowList
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            // Fallback to presentation options
            let isFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            for key in result.keys { result[key] = isFullScreen }
            updateIfChanged(result)
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Use CGDisplayBounds for each screen — it already returns the
        // top-left-origin CG coordinate space, identical to CGWindowList.
        // The previous code derived a "primary height" from
        // `NSScreen.screens.first` and flipped manually; that broke on
        // multi-monitor layouts where the first screen is not the global
        // origin (e.g. external display above the laptop).
        let screenFrames: [(id: CGDirectDisplayID, frame: CGRect)] = screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (id, CGDisplayBounds(id))
        }

        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0  // Normal window layer (fullscreen apps use layer 0)
            else { continue }

            // Skip system processes
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            if ownerName == "Dock" || ownerName == "Window Server"
                || ownerName == "SystemUIServer" || ownerName == "Finder" {
                continue
            }

            let windowFrame = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )

            for (screenID, cgScreenFrame) in screenFrames {
                // 只比较宽高会让"屏幕 A 上的全屏窗口"误判为也覆盖了屏幕 B
                // （当两屏分辨率相同时），从而把 B 的壁纸 orderOut。
                // 改用与目标屏幕的相交面积：当窗口覆盖该屏幕 ≥95% 时才算
                // 真正全屏，避免跨屏误判。
                let intersection = windowFrame.intersection(cgScreenFrame)
                guard !intersection.isNull else { continue }
                let coverage = intersection.width * intersection.height
                let screenArea = cgScreenFrame.width * cgScreenFrame.height
                if screenArea > 0, coverage >= screenArea * 0.95 {
                    result[screenID] = true
                }
            }
        }

        updateIfChanged(result)
    }

    private func updateIfChanged(_ newState: [CGDirectDisplayID: Bool]) {
        if newState != hiddenScreens {
            hiddenScreens = newState
        }
    }

    // MARK: - Public API

    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool {
        hiddenScreens[screenID] ?? false
    }

    func checkNow() {
        checkFullScreenState()
    }
}
