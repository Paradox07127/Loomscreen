import Foundation

public enum HTMLSource: Codable, Equatable, Sendable {
    case file(bookmarkData: Data)
    case folder(bookmarkData: Data, indexFileName: String)
    case url(URL)
    case inline(String)

    /// Migrates legacy persisted data (`WallpaperContent.html(String)`).
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
    /// Rejects scheme-only inputs (`http://`, `http:///path`) by requiring a
    /// non-empty host. Bare `localhost:3000` / `127.0.0.1:3000` / `example.com`
    /// are upgraded to `https://` so the trust store has a real origin to key
    /// off; anything else falls through to inline HTML.
    /// YouTube `watch?v=` / `youtu.be/` / `shorts/` URLs are rewritten to the
    /// cookieless embed form (`youtube-nocookie.com/embed/<id>?…`) so passive
    /// playback works without Google's SSO + sign-in overlay tripping inside
    /// the sandboxed WKWebView.
    public init?(userInput: String) {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = url.host,
           !host.isEmpty {
            self = .url(Self.normalizingForWallpaper(url))
            return
        }

        if Self.looksLikeBareHost(trimmed),
           let url = URL(string: "https://" + trimmed),
           let host = url.host,
           !host.isEmpty {
            self = .url(Self.normalizingForWallpaper(url))
            return
        }

        self = .inline(trimmed)
    }

    /// Rewrites YouTube watch / short links to `youtube-nocookie.com/embed`;
    /// other URLs pass through. Single entry point so future per-host rewrites
    /// (Vimeo, Twitch live, etc.) hang off the same call site.
    public static func normalizingForWallpaper(_ url: URL) -> URL {
        if let videoID = youTubeVideoID(from: url) {
            return youTubeEmbedURL(forID: videoID) ?? url
        }
        return url
    }

    private static func youTubeVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" {
            let id = url.lastPathComponent
            return isPlausibleVideoID(id) ? id : nil
        }

        guard host == "youtube.com"
            || host == "www.youtube.com"
            || host == "m.youtube.com" else { return nil }

        let path = url.path
        if path == "/watch" {
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "v" })?
                .value ?? ""
            return isPlausibleVideoID(id) ? id : nil
        }
        if path.hasPrefix("/shorts/") {
            let id = String(path.dropFirst("/shorts/".count))
                .split(separator: "/").first.map(String.init) ?? ""
            return isPlausibleVideoID(id) ? id : nil
        }
        if path.hasPrefix("/embed/") {
            // Already an embed URL — don't double-rewrite.
            return nil
        }
        return nil
    }

    private static func isPlausibleVideoID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 20 else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    private static func youTubeEmbedURL(forID id: String) -> URL? {
        // `youtube-nocookie.com` skips Google's SSO + ad-personalization
        // cookies that crash passive playback in a sandboxed WKWebView.
        // `playlist=<id>` is the documented hack that lets `loop=1` actually
        // restart the same video instead of stopping at end-of-clip.
        // `mute=1` is required for macOS autoplay policy; users can unmute
        // through the app's Audio slider once playback begins.
        //
        // Param minimalism is deliberate: deprecated flags (`iv_load_policy=3`,
        // `modestbranding=1`) plus `controls=0` triggered Error 153 on a
        // significant slice of videos. The current set is the minimum that
        // YouTube's IFrame Player API docs still document as supported.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(id)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "mute", value: "1"),
            URLQueryItem(name: "loop", value: "1"),
            URLQueryItem(name: "playlist", value: id),
        ]
        return components.url
    }

    /// Whitelist of characters valid in a hostname / IPv4 / IPv6-with-brackets /
    /// port suffix. Prevents inline HTML / CSS / JS like `console.log("x")` or
    /// `border-radius: 4px` — which contain dots — from being misclassified
    /// as bare hosts and silently turned into network requests.
    private static let bareHostAllowedScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: ".-:[]")
        return set
    }()

    private static func looksLikeBareHost(_ input: String) -> Bool {
        guard !input.isEmpty else { return false }
        guard input.unicodeScalars.allSatisfy({ bareHostAllowedScalars.contains($0) }) else {
            return false
        }
        let lower = input.lowercased()
        if lower == "localhost" || lower.hasPrefix("localhost:") { return true }
        if input.contains(".") {
            // Reject leading/trailing dot ("." / ".foo" / "foo.") — Foundation
            // would still parse it but it's never a real host.
            guard input.first != ".", input.last != "." else { return false }
            return true
        }
        // bare host:port like `myhost:8080`
        if let colonIndex = input.firstIndex(of: ":") {
            let portPart = input[input.index(after: colonIndex)...]
            if !portPart.isEmpty, portPart.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
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

    /// HTML sources are restored when the user switches back from video/shader modes.
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
