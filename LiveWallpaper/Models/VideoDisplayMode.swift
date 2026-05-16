import SwiftUI

enum VideoDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perDisplay = "Per Display"
    case spanAllDisplays = "Span All Displays"

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .perDisplay: return "Per Display"
        case .spanAllDisplays: return "Span"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .perDisplay: return "Each display renders its own full video frame"
        case .spanAllDisplays: return "Crop one video across the full display layout"
        }
    }
}
