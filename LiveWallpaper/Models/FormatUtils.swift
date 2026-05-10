import Foundation

enum FormatUtils {
    nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    static func formatBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytes))
    }

    static func formatPercent(_ percent: Double) -> String {
        formatFractionAsPercent(percent / 100)
    }

    static func formatFractionAsPercent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return clamped.formatted(.percent.precision(.fractionLength(0)))
    }

    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, !seconds.isNaN else { return "Unknown" }
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
