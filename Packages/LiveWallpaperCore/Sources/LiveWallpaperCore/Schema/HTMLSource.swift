import Foundation

/// Persisted source for an HTML wallpaper.
public enum HTMLSource: Codable, Equatable, Sendable {
    case file(bookmarkData: Data)
    case folder(bookmarkData: Data, indexFileName: String)
    case url(URL)
    case inline(String)

    /// Heuristic constructor used when migrating legacy persisted data (`WallpaperContent.html(String)`).
    public init(legacyString: String) {
        let trimmed = legacyString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self = .inline("")
            return
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            self = .url(url)
            return
        }
        self = .inline(trimmed)
    }

    /// User-typed string from the inspector / menu bar URL field.
    public init?(userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            self = .url(url)
            return
        }
        if trimmed.contains("."),
           let url = URL(string: "https://" + trimmed),
           let host = url.host, host.contains(".") {
            self = .url(url)
            return
        }
        self = .inline(trimmed)
    }

    public var displayName: String {
        switch self {
        case .file(let bookmark):
            return ResourceUtilities.resolveBookmarkName(bookmark) ?? "Local file"
        case .folder(let bookmark, let index):
            let folderName = ResourceUtilities.resolveBookmarkName(bookmark) ?? "Folder"
            return "\(folderName)/\(index)"
        case .url(let url):
            return url.host ?? url.absoluteString
        case .inline:
            return "Inline HTML"
        }
    }

    /// SF Symbol used to represent this source in inspector and menu bar.
    public var iconName: String {
        switch self {
        case .file: return "doc.richtext"
        case .folder: return "folder"
        case .url: return "globe"
        case .inline: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// `true` when the underlying transport is HTTP (insecure). Inspector
    /// shows a warning banner when this is true.
    public var isInsecureURL: Bool {
        if case .url(let url) = self {
            return url.scheme?.lowercased() == "http"
        }
        return false
    }

    /// True for user-selected HTML sources that should be restored when the
    /// user switches back from video/shader modes.
    public var isRestorableHTMLSource: Bool {
        true
    }

    /// Stable identity used to detect the same source running on multiple
    /// screens (multi-instance audio + GPU avoidance). Equatable already
    /// gives us comparison; this gives us a Dictionary key.
    public var diagnosticSignature: String {
        switch self {
        case .file(let data):
            return "file:" + data.base64EncodedString()
        case .folder(let data, let index):
            return "folder:" + data.base64EncodedString() + ":" + index
        case .url(let url):
            return "url:" + url.absoluteString
        case .inline(let html):
            return "inline:" + String(html.hashValue)
        }
    }
}
