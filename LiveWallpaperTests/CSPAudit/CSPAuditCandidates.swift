/// CSP candidates ordered from a restrictive baseline through the shipping policy to a compatibility fallback.
enum CSPAuditCandidate: String, CaseIterable, Sendable {
    case v1Strict
    case v2Current
    case v3Relaxed

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
