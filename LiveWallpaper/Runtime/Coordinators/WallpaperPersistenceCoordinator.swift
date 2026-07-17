import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Centralises the write side of `ScreenConfiguration` persistence (save /
/// remove / prune, each posting `.wallpaperConfigurationDidChange`).
///
/// Reads stay on the store directly — call sites elsewhere keep using
/// `configurationStore.get(for:)` / `.loadAll()` because reads have no side
/// effects to centralise.
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

    func save(_ configuration: ScreenConfiguration) {
        primeDisplayNames(from: configuration)
        store.save(configuration)
        postChange(for: configuration.screenID)
    }

    func remove(for screenID: CGDirectDisplayID) {
        store.remove(for: screenID)
        postChange(for: screenID)
    }

    func primeDisplayNames(from configuration: ScreenConfiguration) {
        bookmarkDisplayNameCache.prime(bookmarks: Self.videoBookmarks(in: configuration))
    }

    /// Drops configurations whose local resource bookmark no longer resolves.
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

    /// Deferred to the next main-actor tick so subscribers run outside the current SwiftUI reconcile pass.
    private func postChange(for screenID: CGDirectDisplayID) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .wallpaperConfigurationDidChange,
                object: nil,
                userInfo: ["screenID": screenID]
            )
        }
    }

    private static func videoBookmarks(in configuration: ScreenConfiguration) -> [Data] {
        var result: [Data] = []
        var seen: Set<Data> = []

        func append(_ bookmarkData: Data?) {
            guard let bookmarkData,
                  !bookmarkData.isEmpty,
                  seen.insert(bookmarkData).inserted else { return }
            result.append(bookmarkData)
        }

        if case .video(let bookmarkData, _) = configuration.activeWallpaper {
            append(bookmarkData)
        }
        append(configuration.savedVideoBookmarkData)
        configuration.playlistBookmarks?.forEach { append($0) }
        configuration.scheduleSlots?.forEach { append($0.videoBookmarkData) }

        return result
    }
}
