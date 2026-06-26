import Foundation
import Observation

@MainActor
public protocol TrustedHostPersisting {
    func load() -> [String]
    func save(_ origins: [String])
}

/// Allowlist of remote HTML wallpaper origins that may run JavaScript.
///
/// The Core type itself is persistence-agnostic — callers inject any
/// `TrustedHostPersisting` implementation. The main app supplies a
/// `SettingsManager`-backed variant in `TrustedHostStore+Shared.swift`
/// (still in the main target because it reaches into SettingsManager).
@MainActor
@Observable
public final class TrustedHostStore {
    /// Sorted, de-duped, HTTPS-only browser origins.
    public private(set) var origins: [TrustedHTMLOrigin]
    @ObservationIgnored private let persistence: any TrustedHostPersisting

    public init(persistence: any TrustedHostPersisting) {
        self.persistence = persistence
        let loaded = persistence.load()
        self.origins = Self.normalizeOrigins(loaded)
        if loaded != hosts {
            persistence.save(hosts)
        }
    }

    /// Raw persisted values. Kept under the old name for compatibility with
    /// settings cleanup and older tests; values are now origin strings.
    public var hosts: [String] { origins.map(\.rawValue) }

    /// Always-trusted origins. These are the *embed-only* surfaces of major
    /// video / media platforms — designed by the platform to be loaded inside
    /// third-party players, with no SSO / general-web JavaScript attack
    /// surface beyond the embedded player itself. We pre-trust them because:
    ///   1. `HTMLSource.normalizingForWallpaper(_:)` actively *rewrites*
    ///      user-typed YouTube watch / shorts / share URLs to these origins,
    ///      so requiring the user to manually trust them would break the
    ///      "just paste a URL" UX.
    ///   2. The risk of pre-trusting them is bounded — these domains serve
    ///      nothing but their own embed pages.
    /// Kept distinct from user-trusted origins so they can never be revoked
    /// and never persist (a future macOS update shipping with no built-ins
    /// would not strand stale entries in user defaults).
    public static let builtInTrustedOrigins: Set<TrustedHTMLOrigin> = {
        let raw = [
            "https://www.youtube-nocookie.com",
            "https://youtube-nocookie.com",
            "https://player.vimeo.com",
        ]
        return Set(raw.compactMap(TrustedHTMLOrigin.init(persistedValue:)))
    }()

    public var originSet: Set<TrustedHTMLOrigin> {
        Set(origins).union(Self.builtInTrustedOrigins)
    }
    public var hostSet: Set<String> { Set(originSet.map(\.rawValue)) }

    /// True when `origin` is on the immutable built-in allowlist. UI uses
    /// this to hide / disable the Revoke control for built-ins.
    public func isBuiltInTrusted(_ origin: TrustedHTMLOrigin) -> Bool {
        Self.builtInTrustedOrigins.contains(origin)
    }

    public func contains(_ host: String) -> Bool {
        guard let origin = TrustedHTMLOrigin(persistedValue: host) else { return false }
        return contains(origin)
    }

    public func contains(_ origin: TrustedHTMLOrigin) -> Bool {
        originSet.contains(origin)
    }

    public func contains(url: URL) -> Bool {
        guard let origin = TrustedHTMLOrigin(url: url) else { return false }
        return contains(origin)
    }

    @discardableResult
    public func trust(_ host: String) -> Bool {
        guard let origin = TrustedHTMLOrigin(persistedValue: host) else { return false }
        return trust(origin)
    }

    @discardableResult
    public func trust(_ origin: TrustedHTMLOrigin) -> Bool {
        guard origin.isSecure, !originSet.contains(origin) else { return false }
        origins = Self.normalizeOrigins(hosts + [origin.rawValue])
        persist()
        return true
    }

    @discardableResult
    public func revoke(_ host: String) -> Bool {
        guard let origin = TrustedHTMLOrigin(persistedValue: host) else { return false }
        return revoke(origin)
    }

    @discardableResult
    public func revoke(_ origin: TrustedHTMLOrigin) -> Bool {
        guard !Self.builtInTrustedOrigins.contains(origin) else { return false }
        guard origins.contains(origin) else { return false }
        origins.removeAll { $0 == origin }
        persist()
        return true
    }

    public func resetAfterSettingsCleared() {
        origins.removeAll()
    }

    private func persist() {
        persistence.save(hosts)
    }

    public static func normalize(_ raw: [String]) -> [String] {
        normalizeOrigins(raw).map(\.rawValue)
    }

    public static func normalizeOrigins(_ raw: [String]) -> [TrustedHTMLOrigin] {
        Array(Set(raw.compactMap(TrustedHTMLOrigin.init(persistedValue:))
            .filter(\.isSecure)))
            .sorted()
    }
}
