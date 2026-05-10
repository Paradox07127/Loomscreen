import Foundation
import Observation

/// Persistence seam for the trusted-origin allowlist.
@MainActor
protocol TrustedHostPersisting {
    func load() -> [String]
    func save(_ origins: [String])
}

@MainActor
struct SettingsManagerTrustedHostPersistence: TrustedHostPersisting {
    func load() -> [String] { SettingsManager.shared.loadTrustedHosts() }
    func save(_ origins: [String]) { SettingsManager.shared.saveTrustedHosts(origins) }
}

/// Allowlist of remote HTML wallpaper origins that may run JavaScript.
@MainActor
@Observable
final class TrustedHostStore {
    static let shared = TrustedHostStore()

    /// Sorted, de-duped, HTTPS-only browser origins.
    private(set) var origins: [TrustedHTMLOrigin]
    @ObservationIgnored private let persistence: any TrustedHostPersisting

    init(persistence: any TrustedHostPersisting = SettingsManagerTrustedHostPersistence()) {
        self.persistence = persistence
        let loaded = persistence.load()
        self.origins = Self.normalizeOrigins(loaded)
        if loaded != hosts {
            persistence.save(hosts)
        }
    }

    /// Raw persisted values. Kept under the old name for compatibility with
    /// settings cleanup and older tests; values are now origin strings.
    var hosts: [String] { origins.map(\.rawValue) }

    var originSet: Set<TrustedHTMLOrigin> { Set(origins) }
    var hostSet: Set<String> { Set(hosts) }

    func contains(_ host: String) -> Bool {
        guard let origin = TrustedHTMLOrigin(persistedValue: host) else { return false }
        return contains(origin)
    }

    func contains(_ origin: TrustedHTMLOrigin) -> Bool {
        originSet.contains(origin)
    }

    func contains(url: URL) -> Bool {
        guard let origin = TrustedHTMLOrigin(url: url) else { return false }
        return contains(origin)
    }

    @discardableResult
    func trust(_ host: String) -> Bool {
        guard let origin = TrustedHTMLOrigin(persistedValue: host) else { return false }
        return trust(origin)
    }

    @discardableResult
    func trust(_ origin: TrustedHTMLOrigin) -> Bool {
        guard origin.isSecure, !originSet.contains(origin) else { return false }
        origins = Self.normalizeOrigins(hosts + [origin.rawValue])
        persist()
        return true
    }

    @discardableResult
    func revoke(_ host: String) -> Bool {
        guard let origin = TrustedHTMLOrigin(persistedValue: host) else { return false }
        return revoke(origin)
    }

    @discardableResult
    func revoke(_ origin: TrustedHTMLOrigin) -> Bool {
        guard originSet.contains(origin) else { return false }
        origins.removeAll { $0 == origin }
        persist()
        return true
    }

    func resetAfterSettingsCleared() {
        origins.removeAll()
    }

    private func persist() {
        persistence.save(hosts)
    }

    static func normalize(_ raw: [String]) -> [String] {
        normalizeOrigins(raw).map(\.rawValue)
    }

    static func normalizeOrigins(_ raw: [String]) -> [TrustedHTMLOrigin] {
        Array(Set(raw.compactMap(TrustedHTMLOrigin.init(persistedValue:))
            .filter(\.isSecure)))
            .sorted()
    }
}
