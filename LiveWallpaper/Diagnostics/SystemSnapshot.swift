import AppKit
import Foundation
import LiveWallpaperCore

/// Snapshot of host system + runtime state for the "Report a Bug" sheet.
struct SystemSnapshot: Sendable {
    let appVersion: String
    let appBuild: String
    let sku: SKU
    let macOSVersion: String
    let macOSBuild: String
    let hardwareModel: String
    let chip: String
    let physicalMemoryGiB: Int
    let displays: [DisplayDescriptor]
    let activeWallpaperKinds: [String]
    let bundleIdentifier: String
    let localeIdentifier: String

    enum SKU: String, Sendable {
        case pro = "Pro"
        case lite = "Lite"
    }

    struct DisplayDescriptor: Sendable {
        let pixelWidth: Int
        let pixelHeight: Int
        let backingScaleFactor: Int
    }

    @MainActor
    static func capture(activeWallpaperKinds: [String]) -> SystemSnapshot {
        SystemSnapshot(
            appVersion: bundleString(forKey: "CFBundleShortVersionString") ?? "unknown",
            appBuild: bundleString(forKey: "CFBundleVersion") ?? "unknown",
            sku: currentSKU,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
                .components(separatedBy: " (")
                .first ?? ProcessInfo.processInfo.operatingSystemVersionString,
            macOSBuild: extractMacOSBuild() ?? "unknown",
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            physicalMemoryGiB: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)),
            displays: NSScreen.screens.map { screen in
                DisplayDescriptor(
                    pixelWidth: Int(screen.frame.width * screen.backingScaleFactor),
                    pixelHeight: Int(screen.frame.height * screen.backingScaleFactor),
                    backingScaleFactor: Int(screen.backingScaleFactor)
                )
            },
            activeWallpaperKinds: activeWallpaperKinds,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            localeIdentifier: Locale.current.identifier
        )
    }

    private static var currentSKU: SKU {
        #if LITE_BUILD
        return .lite
        #else
        return .pro
        #endif
    }

    private static func bundleString(forKey key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// Splits the build out of `operatingSystemVersionString`, whose format is
    /// "Version 15.2 (Build 24C101)", into a separately addressable column.
    private static func extractMacOSBuild() -> String? {
        let raw = ProcessInfo.processInfo.operatingSystemVersionString
        guard let openParen = raw.range(of: "(Build "),
              let closeParen = raw.range(of: ")", range: openParen.upperBound..<raw.endIndex)
        else { return nil }
        return String(raw[openParen.upperBound..<closeParen.lowerBound])
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let useful = buffer.prefix(while: { $0 != 0 })
        return String(decoding: useful, as: UTF8.self)
    }
}
