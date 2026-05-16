import Combine
import CoreGraphics
import Foundation

/// Reports the system's power source state so policy can throttle wallpapers on battery.
@MainActor
public protocol PowerMonitoring: AnyObject {
    var powerSourcePublisher: AnyPublisher<PowerMonitor.PowerSource, Never> { get }
    var currentPowerSource: PowerMonitor.PowerSource { get }
    func refreshPowerStatus()
}

extension PowerMonitor: PowerMonitoring {}

/// Reports per-display occlusion by full-screen apps so wallpapers can suspend.
@MainActor
public protocol FullScreenDetecting: AnyObject {
    var hiddenScreens: [CGDirectDisplayID: Bool] { get }
    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool
    func checkNow()
    func setFallbackPollingEnabled(_ enabled: Bool)
}

extension FullScreenDetector: FullScreenDetecting {}
