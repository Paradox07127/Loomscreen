import SwiftUI

public enum VideoDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perDisplay = "Per Display"
    case spanAllDisplays = "Span All Displays"

    public var id: String { rawValue }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .perDisplay: return "Per Display"
        case .spanAllDisplays: return "Span"
        }
    }

    public var descriptionKey: LocalizedStringKey {
        switch self {
        case .perDisplay: return "Each display renders its own full video frame"
        case .spanAllDisplays: return "Crop one video across the full display layout"
        }
    }
}
