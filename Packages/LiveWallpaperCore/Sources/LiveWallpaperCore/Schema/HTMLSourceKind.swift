import SwiftUI

public enum HTMLSourceKind: String, CaseIterable, Identifiable, Sendable {
    case url, file, folder

    public var id: String { rawValue }

    public var labelKey: LocalizedStringKey {
        switch self {
        case .url: return "URL"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }

    public var icon: String {
        switch self {
        case .url: return "globe"
        case .file: return "doc.richtext"
        case .folder: return "folder"
        }
    }
}
