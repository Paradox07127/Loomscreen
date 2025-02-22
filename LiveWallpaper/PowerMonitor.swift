import Foundation
import IOKit.ps

extension Notification.Name {
    static let powerSourceChanged = Notification.Name("powerSourceChanged")
}

class PowerMonitor {
    static let shared = PowerMonitor()
    
    private var powerSourceCallback: IOPowerSourceCallbackType = { _ in
        NotificationCenter.default.post(name: .powerSourceChanged, object: nil)
    }
    
    private init() {
        // Create and add power source observer to runloop
        if let runLoopSource = IOPSNotificationCreateRunLoopSource(powerSourceCallback, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }
    
    var isOnBattery: Bool {
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        
        guard let sources = sources,
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeRetainedValue() as? [String: Any],
              let isPlugged = description[kIOPSPowerSourceStateKey] as? String else {
            return false
        }
        
        return isPlugged != kIOPSACPowerValue
    }
}
