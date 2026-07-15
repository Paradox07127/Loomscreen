#if !LITE_BUILD
import Foundation
import Observation

/// Bundles the Workshop online actors behind one `@Observable` host for
/// `@Environment(WorkshopServices.self)`. Actors aren't `@Observable`, so the
/// container mirrors `hasWebAPIKey` for UI bindings to read synchronously.
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
