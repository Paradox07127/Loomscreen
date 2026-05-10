import Foundation

struct ScheduleSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var startHour: Int
    var endHour: Int
    var videoBookmarkData: Data?
    var label: String

    static let defaultSlots: [ScheduleSlot] = [
        ScheduleSlot(startHour: 6, endHour: 12, label: "Morning"),
        ScheduleSlot(startHour: 12, endHour: 18, label: "Afternoon"),
        ScheduleSlot(startHour: 18, endHour: 22, label: "Evening"),
        ScheduleSlot(startHour: 22, endHour: 6, label: "Night"),
    ]

    func containsHour(_ hour: Int) -> Bool {
        if startHour <= endHour {
            return hour >= startHour && hour < endHour
        } else {
            return hour >= startHour || hour < endHour
        }
    }

    var localizedLabel: String {
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
