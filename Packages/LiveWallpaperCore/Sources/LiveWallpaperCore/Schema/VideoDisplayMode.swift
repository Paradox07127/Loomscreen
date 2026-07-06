import SwiftUI

public enum VideoDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perDisplay = "Per Display"
    case spanAllDisplays = "Span All Displays"

    public var id: String { rawValue }
}
