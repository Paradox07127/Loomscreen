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
    var occludedScreens: [CGDirectDisplayID: Bool] { get }
    /// Per-display union-coverage fraction (0…1), quantized so observers only
    /// wake on meaningful change. The continuous source behind the binary
    /// `occludedScreens` (≥0.85), used by adaptive frame-rate throttling.
    var occlusionFractions: [CGDirectDisplayID: CGFloat] { get }
    func isDesktopHidden(for screenID: CGDirectDisplayID) -> Bool
    func isDesktopOccluded(for screenID: CGDirectDisplayID) -> Bool
    func occlusionFraction(for screenID: CGDirectDisplayID) -> Double
    func checkNow()
    func setFallbackPollingEnabled(_ enabled: Bool)
    /// Permanently releases notification subscriptions and polling owned by
    /// this detector instance. Used by application teardown, not by the
    /// adaptive polling toggle.
    func stop()
}

extension FullScreenDetector: FullScreenDetecting {}
