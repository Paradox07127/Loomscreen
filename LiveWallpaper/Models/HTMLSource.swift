import Foundation

/// Persisted source for an HTML wallpaper.
enum HTMLSource: Codable, Equatable, Sendable {
    case file(bookmarkData: Data)
    case folder(bookmarkData: Data, indexFileName: String)
    case url(URL)
    case inline(String)

    /// Heuristic constructor used when migrating legacy persisted data
    /// (`WallpaperContent.html(String)`). Recognized URL schemes become
    /// `.url`; everything else falls back to `.inline` because raw file
    /// paths cannot be re-resolved without a bookmark.
    init(legacyString: String) {
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

    /// User-typed string from the inspector / menu bar URL field. Auto-prefixes
    /// `https://` when no scheme is supplied so users can type "example.com".
    /// Returns `nil` for empty input.
    init?(userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Only HTTP(S) URLs are accepted as `.url`. `file://` schemes are
        // intentionally rejected — local content must come through `.file`
        // or `.folder` so a security-scoped bookmark is captured.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            self = .url(url)
            return
        }
        // Auto-prefix `https://` only when the input plausibly looks like a
        // domain — i.e. contains at least one `.` separating host segments.
        // Without this, typing "abc" would build `https://abc` whose host is
        // technically non-nil but never resolvable.
        if trimmed.contains("."),
           let url = URL(string: "https://" + trimmed),
           let host = url.host, host.contains(".") {
            self = .url(url)
            return
        }
        self = .inline(trimmed)
    }

    var displayName: String {
        switch self {
        case .file(let bookmark):
            return BookmarkNameResolver.lastPathComponent(from: bookmark) ?? "Local file"
        case .folder(let bookmark, let index):
            let folderName = BookmarkNameResolver.lastPathComponent(from: bookmark) ?? "Folder"
            return "\(folderName)/\(index)"
        case .url(let url):
            return url.host ?? url.absoluteString
        case .inline:
            return "Inline HTML"
        }
    }

    /// SF Symbol used to represent this source in inspector and menu bar.
    var iconName: String {
        switch self {
        case .file: return "doc.richtext"
        case .folder: return "folder"
        case .url: return "globe"
        case .inline: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// `true` when the underlying transport is HTTP (insecure). Inspector
    /// shows a warning banner when this is true.
    var isInsecureURL: Bool {
        if case .url(let url) = self {
            return url.scheme?.lowercased() == "http"
        }
        return false
    }

    /// Stable identity used to detect the same source running on multiple
    /// screens (multi-instance audio + GPU avoidance). Equatable already
    /// gives us comparison; this gives us a Dictionary key.
    var diagnosticSignature: String {
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
