import Foundation

public struct ScheduleSlot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var startHour: Int
    public var endHour: Int
    public var videoBookmarkData: Data?
    public var label: String

    public init(
        id: UUID = UUID(),
        startHour: Int,
        endHour: Int,
        videoBookmarkData: Data? = nil,
        label: String
    ) {
        self.id = id
        self.startHour = startHour
        self.endHour = endHour
        self.videoBookmarkData = videoBookmarkData
        self.label = label
    }

    /// Fresh template every access — a `static let` would freeze the four
    /// UUIDs at launch, so two displays share identical slot IDs, `ForEach`
    /// can't distinguish rows, and per-row `@State` leaks across screen swaps.
    public static var defaultSlots: [ScheduleSlot] {
        [
            ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"),
            ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon"),
            ScheduleSlot(startHour: 18, endHour: 22, label: "Evening"),
            ScheduleSlot(startHour: 22, endHour: 6, label: "Night"),
        ]
    }

    public func containsHour(_ hour: Int) -> Bool {
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            return hour >= startHour || hour < endHour
        }
    }

    /// True when the slot crosses midnight (e.g. 22 → 6). Zero-length slots
    /// are reported as non-wrapping; callers reject them upstream.
    public var wraps: Bool {
        startHour > endHour
    }

    /// Slot decomposed into clipped `[start, end)` half-open ranges within the
    /// visible 0–24 timeline. Non-wrapping → one segment; wrapping → one or two
    /// (`[start, 24)` + `[0, end)`); zero-length → none. Empty halves (e.g. slot
    /// `1 → 0` whose second half would be `[0, 0)`) are filtered so consumers
    /// never need to skip them.
    public func timelineSegments() -> [TimelineSegment] {
        if startHour == endHour { return [] }
        if startHour < endHour {
            return [TimelineSegment(start: startHour, end: endHour, wraps: false)]
        }
        var segments: [TimelineSegment] = []
        if startHour < 24 {
            segments.append(TimelineSegment(start: startHour, end: 24, wraps: true))
        }
        if endHour > 0 {
            segments.append(TimelineSegment(start: 0, end: endHour, wraps: true))
        }
        return segments
    }

    public struct TimelineSegment: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let wraps: Bool

        public init(start: Int, end: Int, wraps: Bool) {
            self.start = start
            self.end = end
            self.wraps = wraps
        }
    }

    public var localizedLabel: String {
        switch label {
        case "Morning":
            return String(localized: "Morning", defaultValue: "Morning", comment: "Default schedule slot name.")
        case "Midday":
            return String(localized: "Midday", defaultValue: "Midday", comment: "Default schedule slot name.")
        case "Afternoon":
            return String(localized: "Afternoon", defaultValue: "Afternoon", comment: "Default schedule slot name.")
        case "Evening":
            return String(localized: "Evening", defaultValue: "Evening", comment: "Default schedule slot name.")
        case "Night":
            return String(localized: "Night", defaultValue: "Night", comment: "Default schedule slot name.")
        default:
            return label
        }
    }
}
