import Foundation

/// Candidate Content-Security-Policy strings tested against the live Wallpaper
/// Engine web-wallpaper corpus per
/// `docs/2026-05-28-steam-workshop-integration-plan.md` Phase 0 step 10.
///
/// The three candidates form an axis of strictness:
/// - `v1Strict`   : original rev-3 baseline; `connect-src` blocks all
///                   outbound HTTPS, which is suspected to break weather /
///                   clock / news widgets but locks down exfiltration.
/// - `v2Current`  : the policy currently shipped on `main` (see
///                   `FolderURLSchemeHandler.contentSecurityPolicy`); allows
///                   outbound HTTPS for `connect-src` / `img-src` /
///                   `media-src` / `font-src`. Pass threshold for shipping:
///                   ≥95 % of projects report zero violations.
/// - `v3Relaxed`  : fallback if v2 still breaks too many wallpapers; adds
///                   `script-src 'self' https: 'unsafe-inline' 'unsafe-eval'`
///                   so wallpapers that load third-party JS (e.g. CDN-hosted
///                   p5.js, three.js) keep working.
enum CSPAuditCandidate: String, CaseIterable, Sendable {
    case v1Strict
    case v2Current
    case v3Relaxed

    /// Directive string suitable for `Content-Security-Policy-Report-Only`.
    var directives: String {
        switch self {
        case .v1Strict:
            return [
                "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
                "connect-src 'self' livewallpaper: data: blob:;",
                "img-src 'self' data: blob: livewallpaper:;",
                "media-src 'self' data: blob: livewallpaper:;",
                "font-src 'self' data: livewallpaper:;",
                "frame-src 'none';",
                "object-src 'none';",
                "base-uri 'none';",
                "form-action 'none';"
            ].joined(separator: " ")
        case .v2Current:
            return [
                "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
                "connect-src 'self' https: livewallpaper: data: blob:;",
                "img-src 'self' https: data: blob: livewallpaper:;",
                "media-src 'self' https: data: blob: livewallpaper:;",
                "font-src 'self' https: data: livewallpaper:;",
                "frame-src 'none';",
                "object-src 'none';",
                "base-uri 'none';",
                "form-action 'none';"
            ].joined(separator: " ")
        case .v3Relaxed:
            return [
                "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
                "script-src 'self' https: 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
                "connect-src 'self' https: livewallpaper: data: blob:;",
                "img-src 'self' https: data: blob: livewallpaper:;",
                "media-src 'self' https: data: blob: livewallpaper:;",
                "font-src 'self' https: data: livewallpaper:;",
                "frame-src 'none';",
                "object-src 'none';",
                "base-uri 'none';",
                "form-action 'none';"
            ].joined(separator: " ")
        }
    }

    var displayName: String {
        switch self {
        case .v1Strict:  return "v1-strict (no https connect-src)"
        case .v2Current: return "v2-current (ship config)"
        case .v3Relaxed: return "v3-relaxed (script-src https:)"
        }
    }
}
