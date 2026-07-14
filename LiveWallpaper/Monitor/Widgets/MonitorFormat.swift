import Foundation

/// User-facing temperature unit for the monitor widgets' sensor readouts.
/// DISPLAY-only: every internal threshold (temperature colour ramp, hot/warm
/// bands) stays in Celsius; only the printed value + symbol convert. The
/// inspector's unit picker writes the defaults key; widgets re-read it on
/// every 1 Hz render, so a flip shows on the next tick.
enum MonitorTemperature {
    static let fahrenheitDefaultsKey = "MonitorTemperatureFahrenheit"

    static var isFahrenheit: Bool {
        UserDefaults.standard.bool(forKey: fahrenheitDefaultsKey)
    }

    static var symbol: String { isFahrenheit ? "°F" : "°C" }

    /// Whole-number reading in the user's unit ("62" / "144").
    static func valueText(_ celsius: Double) -> String {
        let c = celsius.isFinite ? celsius : 0
        let shown = isFahrenheit ? c * 9 / 5 + 32 : c
        return "\(Int(shown.rounded()))"
    }
}

/// Shared display formatters for monitor widgets — 1:1 ports of the mock's
/// JS formatters (index.html) so native output matches the approved design
/// pixel-for-pixel. Thresholds and precision rules are load-bearing; change
/// only in lockstep with the design reference.
enum MonitorFormat {
    static func rate(_ bytesPerSec: Double) -> String {
        let bps = bytesPerSec.isFinite ? max(bytesPerSec, 0) : 0
        if bps < 1 { return "0 B/s" }
        if bps < 1024 { return "\(Int(bps.rounded())) B/s" }
        if bps < 1_048_576 {
            return String(format: bps < 10_240 ? "%.1f KB/s" : "%.0f KB/s", bps / 1024)
        }
        if bps < 1_073_741_824 {
            return String(format: bps < 10_485_760 ? "%.1f MB/s" : "%.0f MB/s", bps / 1_048_576)
        }
        return String(format: "%.1f GB/s", bps / 1_073_741_824)
    }

    static func bytes(_ value: Double) -> String {
        let b = value.isFinite ? max(value, 0) : 0
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1_048_576 { return String(format: "%.0f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.0f MB", b / 1_048_576) }
        return String(format: "%.1f GB", b / 1_073_741_824)
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func gib(_ bytes: Double) -> Double {
        (bytes.isFinite ? bytes : 0) / 1_073_741_824
    }

    /// mm:ss, or h:mm:ss once over an hour (fleet in-status timers).
    static func mmss(_ seconds: Double) -> String {
        let sec = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Compact age: 5s / 3m / 2h / 1d.
    static func ago(_ seconds: Double) -> String {
        let sec = max(0, Int(seconds.isFinite ? seconds : 0))
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec / 60)m" }
        if sec < 86400 { return "\(sec / 3600)h" }
        return "\(sec / 86400)d"
    }

    /// Short countdown: "2h 10m" / "5m" / "30s".
    static func countdown(_ seconds: Double) -> String {
        let sec = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = sec / 3600, m = (sec % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(sec)s"
    }

    /// Days-aware countdown for long windows (weekly quota reset): "3d 5h".
    static func countdownDays(_ seconds: Double) -> String {
        let sec = max(0, Int(seconds.isFinite ? seconds : 0))
        let d = sec / 86400, h = (sec % 86400) / 3600
        if d > 0 { return "\(d)d \(h)h" }
        return countdown(seconds)
    }

    static func usd(_ value: Double?) -> String {
        guard let v = value, v.isFinite else { return "—" }
        if v == 0 { return "$0.00" }
        if v < 10 { return String(format: "$%.2f", v) }
        if v < 1000 { return String(format: "$%.1f", v) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let rounded = NSNumber(value: v.rounded())
        return "$" + (formatter.string(from: rounded) ?? "\(Int(v.rounded()))")
    }

    /// Compact token counts: 842 / 8.4K / 84K / 8.42M / 84.2M.
    static func tokens(_ count: Int) -> String {
        let n = max(count, 0)
        if n < 1000 { return String(n) }
        if n < 1_000_000 {
            let k = Double(n) / 1000
            return n < 10_000 ? String(format: "%.1fK", k) : String(format: "%.0fK", k)
        }
        let m = Double(n) / 1_000_000
        return n < 10_000_000 ? String(format: "%.2fM", m) : String(format: "%.1fM", m)
    }

    /// 0…1 → "42%" (hero percents are always whole numbers in the design).
    static func percent(_ fraction: Double) -> String {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return "\(Int((f * 100).rounded()))%"
    }

    static func interfaceTypeLabel(_ type: String?) -> String {
        switch type {
        case "wifi": return "Wi-Fi"
        case "wiredEthernet", "wired": return "Ethernet"
        case "cellular": return "Cellular"
        case "other": return "Other"
        case let .some(value) where !value.isEmpty:
            return value.prefix(1).uppercased() + value.dropFirst()
        default: return ""
        }
    }
}
