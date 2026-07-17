import LiveWallpaperCore
import SwiftUI

extension WallpaperBookmark {
    var presentationTint: Color {
        switch content {
        case .video: return .blue
        case .html: return .green
        case .metalShader: return .purple
        case .scene: return .orange
        case .monitor: return Color(red: 0.98, green: 0.66, blue: 0.25)
        }
    }

    var subtitleText: Text {
        switch content {
        case .video:
            if let name = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return Text(verbatim: name)
            }
            return Text("Source missing")
        case .html(let source, _):
            return Text(verbatim: source.displayName)
        case .metalShader(let source):
            switch source {
            case .builtin(let preset):
                return Text(verbatim: preset.localizedTitle)
            case .custom:
                return Text("Custom Shader", comment: "Bookmark subtitle for a user-imported Metal shader.")
            }
        case .scene(let descriptor):
            return Text("Workshop \(descriptor.workshopID)", comment: "Bookmark subtitle for a Workshop scene. The placeholder is the Workshop ID.")
        case .monitor:
            return Text("System Monitor", comment: "Bookmark subtitle for the system monitor wallpaper.")
        }
    }
}
