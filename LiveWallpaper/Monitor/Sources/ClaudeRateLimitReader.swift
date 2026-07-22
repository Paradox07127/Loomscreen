import Foundation

/// Account-level rate-limit percentages, already normalized to plain fields the Usage widget understands.
struct ClaudeRateLimits: Sendable, Equatable {
    var fiveHourUsedPercent: Double?
    var fiveHourResetsAt: Double?
    var weekUsedPercent: Double?
    var weekResetsAt: Double?

    /// True when the payload's own timestamp (or the file mtime fallback) is
    /// older than `staleAfter`, so the UI can dim without discarding the numbers.
    var isStale: Bool = false

    var isEmpty: Bool {
        fiveHourUsedPercent == nil && fiveHourResetsAt == nil
            && weekUsedPercent == nil && weekResetsAt == nil
    }
}

/// Reads the freshest Claude Code statusline payload the user's capture script tees to `<root>/livewallpaper-statusline.json`.
struct ClaudeRateLimitReader: Sendable {
    private let fileURL: URL
    private let staleAfter: TimeInterval

    static let payloadFileName = "livewallpaper-statusline.json"
    private static let defaultStaleAfter: TimeInterval = 30 * 60

    init(rootURL: URL, staleAfter: TimeInterval = ClaudeRateLimitReader.defaultStaleAfter) {
        self.fileURL = rootURL.appendingPathComponent(Self.payloadFileName)
        self.staleAfter = staleAfter
    }

    /// Returns the parsed limits, or `nil` when the file is absent, unreadable,
    /// not an object, or carries none of the recognized fields.
    func currentLimits() -> ClaudeRateLimits? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else { return nil }

        let limitsSection = root["rate_limits"] as? [String: Any]
        let fiveHour = limitsSection?["five_hour"] as? [String: Any]
        let sevenDay = limitsSection?["seven_day"] as? [String: Any]

        var limits = ClaudeRateLimits(
            fiveHourUsedPercent: Self.percent(fiveHour?["used_percentage"]),
            fiveHourResetsAt: Self.epoch(fiveHour?["resets_at"]),
            weekUsedPercent: Self.percent(sevenDay?["used_percentage"]),
            weekResetsAt: Self.epoch(sevenDay?["resets_at"])
        )
        guard !limits.isEmpty else { return nil }

        limits.isStale = isStale(root: root)
        return limits
    }

    // MARK: - Freshness

    /// Prefers the payload's own `timestamp`; falls back to the file's mtime so a
    /// script that omits the field still ages out. Missing both ⇒ not stale.
    private func isStale(root: [String: Any]) -> Bool {
        let stamp = Self.epoch(root["timestamp"]) ?? fileModificationEpoch()
        guard let stamp else { return false }
        return Date().timeIntervalSince1970 - stamp > staleAfter
    }

    private func fileModificationEpoch() -> Double? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return modified.timeIntervalSince1970
    }

    // MARK: - Field coercion

    private static func percent(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    /// `resets_at` may be epoch seconds (number or numeric string) or an ISO8601
    /// string; both collapse to epoch seconds. Unparseable ⇒ nil.
    private static func epoch(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String:
            if let numeric = Double(text) { return numeric }
            return Self.parseISO8601(text)?.timeIntervalSince1970
        default:
            return nil
        }
    }

    private static func parseISO8601(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
