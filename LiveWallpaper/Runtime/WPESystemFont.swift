#if !LITE_BUILD
import CoreGraphics
import CoreText

/// WPE references an OS-installed font as `systemfont_<family>` (e.g. `systemfont_arial`, common on
/// clock/date text) rather than a packaged `.ttf`. These have no file to resolve — treating them as
/// asset paths both logs a phantom `fileMissing` AND drops the text to the HelveticaNeue fallback
/// instead of the intended typeface. Map them to the OS font by name instead.
enum WPESystemFont {
    private static let prefix = "systemfont_"

    static func isReference(_ path: String) -> Bool { path.hasPrefix(prefix) }

    /// `systemfont_arial` → `Arial`; `systemfont_comic_sans_ms` → `Comic Sans Ms`. CoreText matches
    /// family names case-insensitively, and an unknown name resolves to a system default (never fails).
    static func familyName(for path: String) -> String {
        path.dropFirst(prefix.count)
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func font(for path: String, size: CGFloat) -> CTFont {
        CTFontCreateWithName(familyName(for: path) as CFString, size, nil)
    }
}
#endif
