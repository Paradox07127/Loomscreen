import AppKit
import Combine

/// Detects when a full-screen app covers the desktop on each display.
/// Uses CGWindowListCopyWindowInfo (no permission required) + workspace notifications.
@MainActor
final class FullScreenDetector: ObservableObject {

    // MARK: - Published State

    @Published private(set) var hiddenScreens: [CGDirectDisplayID: Bool] = [:]

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: AnyCancellable?
    private let pollInterval: TimeInterval

    // MARK: - Initialization

    init(pollInterval: TimeInterval = 5.0) {
        self.pollInterval = pollInterval
        setupNotifications()
        startPolling()
        // Perform initial check
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

    private func startPolling() {
        pollTimer = Timer.publish(every: pollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkFullScreenState() }
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
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

        // Get primary screen height for coordinate conversion
        // CGWindowList uses top-left origin; NSScreen uses bottom-left
        let primaryHeight = screens.first?.frame.height ?? 0

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

            // Check against each screen
            for screen in screens {
                guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    continue
                }

                let sf = screen.frame
                // Convert NSScreen frame (bottom-left origin) to CG coordinates (top-left origin)
                let cgScreenFrame = CGRect(
                    x: sf.origin.x,
                    y: primaryHeight - sf.origin.y - sf.height,
                    width: sf.width,
                    height: sf.height
                )

                // A window covering the full screen dimension indicates fullscreen
                if windowFrame.width >= cgScreenFrame.width &&
                   windowFrame.height >= cgScreenFrame.height {
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
