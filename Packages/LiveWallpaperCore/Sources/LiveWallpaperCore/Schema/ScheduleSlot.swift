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

    public static let defaultSlots: [ScheduleSlot] = [
        ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"),
        ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon"),
        ScheduleSlot(startHour: 18, endHour: 22, label: "Evening"),
        ScheduleSlot(startHour: 22, endHour: 6, label: "Night"),
    ]

    public func containsHour(_ hour: Int) -> Bool {
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            return hour >= startHour || hour < endHour
        }
    }

    public var localizedLabel: String {
        switch label {
        case "Morning":
            return String(localized: "Morning", defaultValue: "Morning", comment: "Default schedule slot name.")
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
