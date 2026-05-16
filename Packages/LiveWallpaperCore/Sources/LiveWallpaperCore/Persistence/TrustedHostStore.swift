import Foundation
import Observation

/// Persistence seam for the trusted-origin allowlist.
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

    public var originSet: Set<TrustedHTMLOrigin> { Set(origins) }
    public var hostSet: Set<String> { Set(hosts) }

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
        guard originSet.contains(origin) else { return false }
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
