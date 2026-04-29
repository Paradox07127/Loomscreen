import Foundation
import Observation

/// Persistence seam for the trusted-host allowlist.
@MainActor
protocol TrustedHostPersisting {
    func load() -> [String]
    func save(_ hosts: [String])
}

@MainActor
struct SettingsManagerTrustedHostPersistence: TrustedHostPersisting {
    func load() -> [String] { SettingsManager.shared.loadTrustedHosts() }
    func save(_ hosts: [String]) { SettingsManager.shared.saveTrustedHosts(hosts) }
}

/// Allowlist of remote HTML wallpaper hosts that may run JavaScript.
@MainActor
@Observable
final class TrustedHostStore {
    static let shared = TrustedHostStore()

    /// Lowercased, sorted, de-duped.
    private(set) var hosts: [String]
    @ObservationIgnored private let persistence: any TrustedHostPersisting

    init(persistence: any TrustedHostPersisting = SettingsManagerTrustedHostPersistence()) {
        self.persistence = persistence
        self.hosts = Self.normalize(persistence.load())
    }

    var hostSet: Set<String> { Set(hosts) }

    func contains(_ host: String) -> Bool {
        hostSet.contains(host.lowercased())
    }

    @discardableResult
    func trust(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !hostSet.contains(normalized) else { return false }
        hosts = Self.normalize(hosts + [normalized])
        persist()
        return true
    }

    @discardableResult
    func revoke(_ host: String) -> Bool {
        let normalized = host.lowercased()
        guard hostSet.contains(normalized) else { return false }
        hosts.removeAll { $0 == normalized }
        persist()
        return true
    }

    private func persist() {
        persistence.save(hosts)
    }

    static func normalize(_ raw: [String]) -> [String] {
        Array(Set(raw.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                       .filter { !$0.isEmpty }))
            .sorted()
    }
}
