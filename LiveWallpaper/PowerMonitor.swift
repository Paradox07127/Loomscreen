import Foundation
import IOKit.ps

final class PowerMonitor {
    static let shared = PowerMonitor()
    static let powerSourceDidChangeNotification = Notification.Name("com.livewallpaper.powerSourceDidChange")
    
    enum PowerSource {
        case internalBattery
        case externalUnlimited
        case externalUPS
        
        var isOnBattery: Bool { self == .internalBattery }
        
        init(identifier: String) {
            switch identifier {
            case kIOPMBatteryPowerKey:
                self = .internalBattery
            case kIOPMACPowerKey:
                self = .externalUnlimited
            case kIOPMUPSPowerKey:
                self = .externalUPS
            default:
                self = .externalUnlimited
                assertionFailure("Unexpected power source identifier: \(identifier)")
            }
        }
    }
    
    // Current power source. When updated, a notification is posted on the main thread.
    private(set) var powerSource: PowerSource {
        didSet {
            if oldValue != powerSource {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Self.powerSourceDidChangeNotification,
                        object: nil,
                        userInfo: ["isOnBattery": self.powerSource.isOnBattery]
                    )
                }
                print("PowerMonitor: Power source changed to \(powerSource) (isOnBattery: \(powerSource.isOnBattery))")
            }
        }
    }
    
    // Run loop source for power notifications.
    private var runLoopSource: CFRunLoopSource?
    
    private init() {
        // Get the initial power source.
        let initialIdentifier = (IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String) ?? kIOPMACPowerKey
        self.powerSource = PowerSource(identifier: initialIdentifier)
        setupPowerNotification()
    }
    
    private func setupPowerNotification() {
        let callback: IOPowerSourceCallbackType = { context in
            // Retrieve self from context.
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context!).takeUnretainedValue()
            monitor.handlePowerChange()
        }
        
        // Create the run loop source to watch for power changes.
        guard let rlSource = IOPSCreateLimitedPowerNotification(callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            print("PowerMonitor: Failed to create power notification run loop source")
            return
        }
        self.runLoopSource = rlSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, .defaultMode)
        print("PowerMonitor: Power notification observer set up")
    }
    
    private func handlePowerChange() {
        // Get the updated power source identifier.
        if let identifier = (IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as? String) {
            let newSource = PowerSource(identifier: identifier)
            self.powerSource = newSource
        }
    }
    
    deinit {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .defaultMode)
        }
    }
}
