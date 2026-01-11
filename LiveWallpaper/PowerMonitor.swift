import Foundation
import IOKit.ps
import Combine

final class PowerMonitor {
    // MARK: - Singleton & Notifications

    static let shared = PowerMonitor()
    static let powerSourceDidChangeNotification = Notification.Name("com.livewallpaper.powerSourceDidChange")

    // MARK: - Power Source Types

    enum PowerSource: Equatable {
        case battery(level: Double)
        case external

        var isOnBattery: Bool {
            if case .battery = self { return true }
            return false
        }

        init(identifier: String) {
            switch identifier {
            case kIOPMBatteryPowerKey:
                self = .battery(level: PowerMonitor.getCurrentBatteryLevel())
            case kIOPMACPowerKey, kIOPMUPSPowerKey:
                self = .external
            default:
                self = .external
            }
        }
    }

    // MARK: - Properties

    private let powerSourceSubject = CurrentValueSubject<PowerSource, Never>(.external)
    private var runLoopSource: CFRunLoopSource?
    private var batteryCheckTimer: Timer?

    var powerSourcePublisher: AnyPublisher<PowerSource, Never> {
        powerSourceSubject.eraseToAnyPublisher()
    }

    var currentPowerSource: PowerSource {
        powerSourceSubject.value
    }

    // MARK: - Initialization

    private init() {
        let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String ?? kIOPMACPowerKey
        powerSourceSubject.send(PowerSource(identifier: source))
        setupPowerNotification()
    }
    
    // MARK: - Power Monitoring Setup

    private func setupPowerNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.handlePowerSourceChange()
        }

        guard let source = IOPSCreateLimitedPowerNotification(
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )?.takeRetainedValue() else { return }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

        if currentPowerSource.isOnBattery {
            startBatteryMonitoring()
        }
    }

    // MARK: - Power State Management

    private func handlePowerSourceChange() {
        guard let sourceString = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String else { return }

        let newSource = PowerSource(identifier: sourceString)
        let oldSource = powerSourceSubject.value

        guard newSource != oldSource else { return }

        Logger.debug("Power source changing from \(oldSource) to \(newSource)", category: .powerMonitor)
        powerSourceSubject.send(newSource)
        postPowerChangeNotification(oldSource: oldSource, newSource: newSource)

        // Log and update battery monitoring
        if case .battery(let level) = newSource {
            Logger.powerSourceChanged(isOnBattery: true, level: level)
            startBatteryMonitoring()
        } else {
            Logger.powerSourceChanged(isOnBattery: false, level: nil)
            stopBatteryMonitoring()
        }
    }

    private func postPowerChangeNotification(oldSource: PowerSource, newSource: PowerSource) {
        NotificationCenter.default.post(
            name: Self.powerSourceDidChangeNotification,
            object: nil,
            userInfo: [
                "isOnBattery": newSource.isOnBattery,
                "previousSource": oldSource,
                "newSource": newSource
            ]
        )
    }
    
    // MARK: - Battery Level Monitoring

    private static func getCurrentBatteryLevel() -> Double {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]

        guard let source = sources?.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
              let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
              let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
              maxCapacity > 0
        else { return 1.0 }

        return Double(currentCapacity) / Double(maxCapacity)
    }

    private func startBatteryMonitoring() {
        stopBatteryMonitoring()
        batteryCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.updateBatteryLevel()
        }
        batteryCheckTimer?.tolerance = 30
    }

    private func stopBatteryMonitoring() {
        batteryCheckTimer?.invalidate()
        batteryCheckTimer = nil
    }

    private func updateBatteryLevel() {
        guard currentPowerSource.isOnBattery else { return }
        let batteryLevel = Self.getCurrentBatteryLevel()
        Logger.debug("Battery level updated: \(Int(batteryLevel * 100))%", category: .powerMonitor)
        powerSourceSubject.send(.battery(level: batteryLevel))
    }

    func refreshPowerStatus() {
        guard let sourceString = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String else { return }

        let newSource = PowerSource(identifier: sourceString)
        let oldSource = powerSourceSubject.value

        if newSource != oldSource {
            powerSourceSubject.send(newSource)
            postPowerChangeNotification(oldSource: oldSource, newSource: newSource)
        }

        if newSource.isOnBattery {
            updateBatteryLevel()
        }
    }

    // MARK: - Cleanup

    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
        stopBatteryMonitoring()
    }
}
