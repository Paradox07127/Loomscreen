import AppKit
import Combine
import Observation

/// Detects when a full-screen app covers a display.
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

    // MARK: - Detection

    private func checkFullScreenState() {
        var result: [CGDirectDisplayID: Bool] = [:]
        let screens = NSScreen.screens

        for screen in screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                result[id] = false
            }
        }

        if !NSScreen.screensHaveSeparateSpaces {
            let isFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            for key in result.keys { result[key] = isFullScreen }
            updateIfChanged(result)
            return
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            let isFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
            for key in result.keys { result[key] = isFullScreen }
            updateIfChanged(result)
            return
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        // CGDisplayBounds already matches CGWindowList's coordinate space.
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
                  layer == 0
            else { continue }

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
                // Intersection avoids cross-triggering same-size displays.
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
