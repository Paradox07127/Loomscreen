import Foundation
import IOKit.ps

class PowerMonitor {
    static let shared = PowerMonitor()
    static let powerSourceDidChangeNotification = Notification.Name("com.livewallpaper.powerSourceDidChange")
    
    private(set) var isOnBattery: Bool = false
    private var notificationToken: NSObjectProtocol?
    
    private init() {
        updatePowerState()
        setupObserver()
    }
    
    private func updatePowerState() {
        let oldState = isOnBattery
        let newState = checkBatteryState()
        
        if oldState != newState {
            isOnBattery = newState
            NotificationCenter.default.post(
                name: Self.powerSourceDidChangeNotification,
                object: nil,
                userInfo: ["isOnBattery": newState]
            )
        }
    }
    
    private func checkBatteryState() -> Bool {
        // Get power source information
        guard let powerInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSourcesList = IOPSCopyPowerSourcesList(powerInfo)?.takeRetainedValue() as NSArray? else {
            return false
        }
        
        // Check each power source
        for powerSource in powerSourcesList {
            guard let description = IOPSGetPowerSourceDescription(powerInfo, powerSource as! CFTypeRef)?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            
            // Check if it's a present internal battery
            guard description[kIOPSIsPresentKey] as? Bool == true,
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
                continue
            }
            
            // Check power state
            let currentState = description[kIOPSPowerSourceStateKey] as? String ?? ""
            if currentState == kIOPSBatteryPowerValue {
                return true
            }
        }
        
        return false
    }
    
    private func setupObserver() {
        notificationToken = NotificationCenter.default.addObserver(
            forName: Notification.Name(kIOPSNotifyPowerSource as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePowerState()
        }
    }
    
    deinit {
        if let token = notificationToken {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
