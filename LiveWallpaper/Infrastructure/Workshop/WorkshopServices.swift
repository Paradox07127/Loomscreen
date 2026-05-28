#if !LITE_BUILD && DIRECT_DISTRIBUTION
import Foundation
import Observation

/// Bundles the Workshop online actors (Keychain, query service, disk cache)
/// behind a single `@Observable` host so SwiftUI views can inject them via
/// `@Environment(WorkshopServices.self)`. Actors themselves aren't
/// `@Observable`, so the container also mirrors the `hasWebAPIKey` flag for
/// UI bindings to read synchronously.
@MainActor
@Observable
final class WorkshopServices {
    @ObservationIgnored let keychain: WorkshopKeychainStore
    @ObservationIgnored let queryCache: WorkshopQueryCache
    @ObservationIgnored let queryService: WorkshopQueryService

    var hasWebAPIKey: Bool = false

    init() {
        let keychain = WorkshopKeychainStore()
        let cache = WorkshopQueryCache()
        self.keychain = keychain
        self.queryCache = cache
        self.queryService = WorkshopQueryService(keychain: keychain, cache: cache)
        Task { @MainActor [weak self] in
            await self?.refreshAPIKeyStatus()
        }
    }

    func refreshAPIKeyStatus() async {
        hasWebAPIKey = await keychain.hasWebAPIKey()
    }
}
#endif
