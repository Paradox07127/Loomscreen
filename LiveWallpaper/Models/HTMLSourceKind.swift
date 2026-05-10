import SwiftUI

enum HTMLSourceKind: String, CaseIterable, Identifiable {
    case url, file, folder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .url: return "URL"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }

    var labelKey: LocalizedStringKey {
        switch self {
        case .url: return "URL"
        case .file: return "File"
        case .folder: return "Folder"
        }
    }

    var icon: String {
        switch self {
        case .url: return "globe"
        case .file: return "doc.richtext"
        case .folder: return "folder"
        }
    }
}
