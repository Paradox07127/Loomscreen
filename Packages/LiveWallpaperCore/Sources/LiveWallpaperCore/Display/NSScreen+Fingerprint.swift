import AppKit
import CoreGraphics

public extension NSScreen {
    /// EDID-derived vendor:model:serial — stable cross-session fallback for `CGDirectDisplayID`.
    var displayFingerprint: String {
        guard let displayID = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return "unknown:\(localizedName)" }

        let vendor = CGDisplayVendorNumber(displayID)
        let model  = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        if vendor == 0 && model == 0 && serial == 0 {
            return "unknown:0:0:0:\(localizedName)"
        }
        return "\(vendor):\(model):\(serial)"
    }
}

public extension String {
    var isUnknownDisplayFingerprint: Bool {
        hasPrefix("unknown:")
    }
}
