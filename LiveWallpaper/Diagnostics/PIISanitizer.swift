import LiveWallpaperCore

/// Compatibility name for UI call sites. The rules live in Core so the same
/// transformation is applied before Console and persistent-log emission.
enum PIISanitizer {
    static func scrub(_ raw: String) -> String {
        LogPrivacyRedactor.scrub(raw)
    }
}
