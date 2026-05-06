import Combine
import Foundation

/// Reports the system's power source state so policy can throttle wallpapers on battery.
@MainActor
protocol PowerMonitoring: AnyObject {
    var powerSourcePublisher: AnyPublisher<PowerMonitor.PowerSource, Never> { get }
    var currentPowerSource: PowerMonitor.PowerSource { get }
    func refreshPowerStatus()
}

extension PowerMonitor: PowerMonitoring {}
