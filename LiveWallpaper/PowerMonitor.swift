import Foundation
import IOKit.ps
import Combine

final class PowerMonitor {
    // MARK: - Singleton & Constants
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
                let batteryLevel = PowerMonitor.getCurrentBatteryLevel()
                self = .battery(level: batteryLevel)
            case kIOPMACPowerKey, kIOPMUPSPowerKey:
                self = .external
            default:
                self = .external
            }
        }
    }
    
    // MARK: - Properties
    private let powerSourceSubject = CurrentValueSubject<PowerSource, Never>(.external)
    private var cleanupTasks: Set<AnyCancellable> = []
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
        setupInitialPowerSource()
        setupPowerNotification()
    }
    
    private func setupInitialPowerSource() {
        let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String ?? kIOPMACPowerKey
        powerSourceSubject.send(PowerSource(identifier: source))
    }
    
    // MARK: - Power Monitoring Setup
    private func setupPowerNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.handlePowerSourceChange()
        }
        
        guard let source = IOPSCreateLimitedPowerNotification(callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }
        
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
        
        // Additional monitoring for battery level changes
        if case .battery = currentPowerSource {
            startBatteryMonitoring()
        }
    }
    
    // MARK: - Power State Management
    private func handlePowerSourceChange() {
        if let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String {
            let newSource = PowerSource(identifier: source)
            let oldSource = powerSourceSubject.value
            
            // Only notify if the power source actually changed
            if newSource != powerSourceSubject.value {
                Logger.debug("Power source changing from \(oldSource) to \(newSource)", category: .powerMonitor)
                powerSourceSubject.send(newSource)
                
                // Post notification with additional info
                NotificationCenter.default.post(
                    name: Self.powerSourceDidChangeNotification,
                    object: nil,
                    userInfo: [
                        "isOnBattery": newSource.isOnBattery,
                        "previousSource": oldSource,
                        "newSource": newSource
                    ]
                )
                
                // Log the power change with the specialized method
                if case .battery(let level) = newSource {
                    Logger.powerSourceChanged(isOnBattery: true, level: level)
                } else {
                    Logger.powerSourceChanged(isOnBattery: false, level: nil)
                }
                
                // Update battery monitoring
                if case .battery = newSource {
                    startBatteryMonitoring()
                } else {
                    stopBatteryMonitoring()
                }
            }
        }
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
        else {
            return 1.0
        }
        
        let level = Double(currentCapacity) / Double(maxCapacity)
        return level
    }
    
    private func startBatteryMonitoring() {
        stopBatteryMonitoring()
        
        // Check battery level every 5 minutes
        batteryCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.updateBatteryLevel()
        }
        batteryCheckTimer?.tolerance = 30 // Allow 30 seconds of tolerance for better power efficiency
        
    }
    
    private func stopBatteryMonitoring() {
        batteryCheckTimer?.invalidate()
        batteryCheckTimer = nil
    }
    
    private func updateBatteryLevel() {
        if case .battery = currentPowerSource {
            let batteryLevel = Self.getCurrentBatteryLevel()
            Logger.debug("Battery level updated: \(Int(batteryLevel * 100))%", category: .powerMonitor)
            powerSourceSubject.send(.battery(level: batteryLevel))
        }
    }
    
    func refreshPowerStatus() {
        if let source = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String {
            let newSource = PowerSource(identifier: source)
            if newSource != powerSourceSubject.value {
                let oldSource = powerSourceSubject.value
                powerSourceSubject.send(newSource)
                
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
            
            // Always update battery level when requested
            if case .battery = newSource {
                updateBatteryLevel()
            }
        }
    }
    
    // MARK: - Cleanup
    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
        stopBatteryMonitoring()
        cleanupTasks.removeAll()
    }
}
