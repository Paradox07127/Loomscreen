import Foundation
import IOKit.ps
import Combine

final class PowerMonitor {
    // MARK: - Singleton & Constants
    static let shared = PowerMonitor()
    static let powerSourceDidChangeNotification = Notification.Name("com.livewallpaper.powerSourceDidChange")
    
    // MARK: - Power Source Types
    enum PowerSource: Equatable {
        case internalBattery(batteryLevel: Double)
        case externalUnlimited
        case externalUPS
        
        var isOnBattery: Bool {
            if case .internalBattery = self { return true }
            return false
        }
        
        init(identifier: String) {
            switch identifier {
            case kIOPMBatteryPowerKey:
                let batteryLevel = PowerMonitor.getCurrentBatteryLevel()
                self = .internalBattery(batteryLevel: batteryLevel)
            case kIOPMACPowerKey:
                self = .externalUnlimited
            case kIOPMUPSPowerKey:
                self = .externalUPS
            default:
                self = .externalUnlimited
            }
        }
    }
    
    // MARK: - Properties
    private let powerSourceSubject = CurrentValueSubject<PowerSource, Never>(.externalUnlimited)
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
        if case .internalBattery = currentPowerSource {
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
                
                // Update battery monitoring
                if case .internalBattery = newSource {
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
        if case .internalBattery = currentPowerSource {
            let batteryLevel = Self.getCurrentBatteryLevel()
            powerSourceSubject.send(.internalBattery(batteryLevel: batteryLevel))
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
            if case .internalBattery = newSource {
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

// MARK: - Publisher Extensions
extension PowerMonitor {
    var batteryLevelPublisher: AnyPublisher<Double, Never> {
        powerSourcePublisher
            .compactMap { powerSource -> Double? in
                if case .internalBattery(let level) = powerSource {
                    return level
                }
                return nil
            }
            .eraseToAnyPublisher()
    }
    
    var isOnBatteryPublisher: AnyPublisher<Bool, Never> {
        powerSourcePublisher
            .map(\.isOnBattery)
            .eraseToAnyPublisher()
    }
}
