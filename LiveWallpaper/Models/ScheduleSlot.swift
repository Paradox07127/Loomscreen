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
}
