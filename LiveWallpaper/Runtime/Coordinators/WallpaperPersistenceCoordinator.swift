import CoreGraphics
import Foundation

/// Centralises the write side of `ScreenConfiguration` persistence:
///
///   `save(_:)` → prime display-name cache → `store.save(_)` →
///                post `.wallpaperConfigurationDidChange`
///   `remove(for:)` → `store.remove(for:)` →
///                post `.wallpaperConfigurationDidChange`
///   `pruneInvalidConfigurations()` → store-side prune →
///                tear down runtime session per removed screen via callback →
///                broadcast `notifyWallpaperSessionChanged`
///   `validateAll()` → per-screen `SettingsManager.validateConfiguration`
///                report
///
/// Borrows refs to the configuration store and the bookmark display-name
/// cache (both live as long as `ScreenManager`). Two callbacks bridge back
/// to runtime concerns that aren't part of persistence proper.
///
/// Reads stay on the store directly — call sites elsewhere in `ScreenManager`
/// and the existing `PlaybackCoordinator` / `WPEImportCoordinator` continue
/// to use `configurationStore.get(for:)` / `.loadAll()` / `.allScreenIDs()`
/// because reads have no side effects to centralise.
@MainActor
final class WallpaperPersistenceCoordinator {
    private let store: WallpaperConfigurationStore
    private let bookmarkDisplayNameCache: BookmarkDisplayNameCache
    private let releaseRuntimeSession: @MainActor (CGDirectDisplayID) -> Void
    private let notifyWallpaperSessionChanged: @MainActor () -> Void

    init(
        store: WallpaperConfigurationStore,
        bookmarkDisplayNameCache: BookmarkDisplayNameCache,
        releaseRuntimeSession: @MainActor @escaping (CGDirectDisplayID) -> Void,
        notifyWallpaperSessionChanged: @MainActor @escaping () -> Void
    ) {
        self.store = store
        self.bookmarkDisplayNameCache = bookmarkDisplayNameCache
        self.releaseRuntimeSession = releaseRuntimeSession
        self.notifyWallpaperSessionChanged = notifyWallpaperSessionChanged
    }

    /// Canonical write path. Primes the display-name cache for any new
    /// bookmark in the configuration, persists, then notifies observers
    /// (the inspector / sidebar listen for
    /// `.wallpaperConfigurationDidChange`).
    func save(_ configuration: ScreenConfiguration) {
        primeDisplayNames(from: configuration)
        store.save(configuration)
        postChange(for: configuration.screenID)
    }

    /// Canonical delete path. Pairs the store removal with the same
    /// configuration-changed notification so observers reload state for the
    /// affected screen.
    func remove(for screenID: CGDirectDisplayID) {
        store.remove(for: screenID)
        postChange(for: screenID)
    }

    /// Bulk-prime the display-name cache for a configuration without
    /// rewriting the store. Used by the launch-time reload pass that walks
    /// existing configurations.
    func primeDisplayNames(from configuration: ScreenConfiguration) {
        bookmarkDisplayNameCache.prime(bookmarks: Self.videoBookmarks(in: configuration))
    }

    /// Drops configurations whose local resource bookmark no longer
    /// resolves. Tears down the runtime session for each removed screen
    /// (via callback) and broadcasts a single session-state-changed if
    /// anything was removed. Returns the removed screen IDs so callers can
    /// log or refresh additional state.
    @discardableResult
    func pruneInvalidConfigurations() -> [CGDirectDisplayID] {
        let removed = store.pruneInvalidResourceConfigurations(
            using: SettingsManager.shared.validateConfiguration
        )
        guard !removed.isEmpty else { return [] }
        for screenID in removed {
            releaseRuntimeSession(screenID)
        }
        notifyWallpaperSessionChanged()
        return removed
    }

    /// Read-only validation report. Walks every stored screen ID and asks
    /// `SettingsManager` to verify it. No persistence side effects.
    func validateAll() -> (valid: Int, invalid: Int) {
        var validCount = 0
        var invalidCount = 0

        for screenID in store.allScreenIDs() {
            if SettingsManager.shared.validateConfiguration(for: screenID) {
                validCount += 1
            } else {
                invalidCount += 1
                Logger.warning("Invalid configuration found for screen \(screenID)", category: .settings)
            }
        }

        Logger.info(
            "Configuration validation complete: \(validCount) valid, \(invalidCount) invalid",
            category: .settings
        )
        return (validCount, invalidCount)
    }

    private func postChange(for screenID: CGDirectDisplayID) {
        NotificationCenter.default.post(
            name: .wallpaperConfigurationDidChange,
            object: nil,
            userInfo: ["screenID": screenID]
        )
    }

    /// All video-bookmark `Data` values referenced by a configuration.
    /// Used to prime the display-name cache when a configuration is saved
    /// or bulk-reloaded. Walks active wallpaper, the saved fallback,
    /// playlist bookmarks, and schedule slots (deduped).
    private static func videoBookmarks(in configuration: ScreenConfiguration) -> [Data] {
        var result: [Data] = []
        var seen: Set<Data> = []

        func append(_ bookmarkData: Data?) {
            guard let bookmarkData,
                  !bookmarkData.isEmpty,
                  seen.insert(bookmarkData).inserted else { return }
            result.append(bookmarkData)
        }

        if case .video(let bookmarkData) = configuration.activeWallpaper {
            append(bookmarkData)
        }
        append(configuration.savedVideoBookmarkData)
        configuration.playlistBookmarks?.forEach { append($0) }
        configuration.scheduleSlots?.forEach { append($0.videoBookmarkData) }

        return result
    }
}
