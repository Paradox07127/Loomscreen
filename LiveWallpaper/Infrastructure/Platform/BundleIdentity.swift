import Foundation

/// SKU-aware brand strings derived from the host bundle's Info.plist, so
/// SwiftUI views and AppKit surfaces show the right product name without
/// `#if LITE_BUILD` peppered through view code. Pro reads "LiveWallpaper"
/// from `LiveWallpaperInfo.plist`; Loomscreen Lite reads "Loomscreen" from
/// `LoomscreenInfo.plist`. Falls back to the Pro string only in test
/// runners where `Bundle.main` is the xctest harness.
enum BundleIdentity {
    static let productDisplayName: String = {
        if let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.isEmpty {
            return display
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return "LiveWallpaper"
    }()
}
