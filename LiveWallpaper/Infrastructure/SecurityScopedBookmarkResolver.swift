import Foundation

/// Single point of resolution for every security-scoped bookmark in the app.
///
/// `bookmarkDataIsStale` MUST be observed every time a bookmark is resolved
/// — Apple gives a one-shot grace use, then the next resolve permanently
/// fails. Historically that flag was dropped at 13 of 16 resolution sites,
/// causing user-granted folder access (Workshop library, engine assets,
/// aerials directory, video files, HTML folders) to silently invalidate
/// after restart or after the underlying inode changed.
///
/// This type centralises resolution so each bookmark kind goes through one
/// path, and a typed `Target` carries the closure that writes refreshed
/// data back to its owning store. Adding a new bookmark kind = adding one
/// `Target` extension; the resolver itself never has to learn about
/// `UserDefaults` keys or persistence schemas.
///
/// Tests inject their own `SecurityScopedBookmarkResolver(resolveData:refreshData:)`
/// to drive the stale path without touching real bookmarks.
struct SecurityScopedBookmarkResolver: Sendable {
    /// Identifies WHERE to persist a refreshed bookmark. The closure runs
    /// when the resolver detects `isStale == true` and successfully
    /// recreates the bookmark. Closure is `@Sendable` so the resolver can
    /// be called from any isolation; typed targets that need MainActor
    /// access dispatch internally.
    ///
    /// The closure receives BOTH the original (stale) bookmark Data and
    /// the freshly recreated Data. Typed targets must compare-and-swap
    /// against the currently stored value before writing — if the user
    /// cleared or re-granted the bookmark between resolve and save, the
    /// stored value will differ and the late save must be a no-op so it
    /// can't resurrect a stale grant.
    struct Target: Sendable {
        let label: String
        let save: @Sendable (_ original: Data, _ refreshed: Data) -> Void

        init(
            label: String,
            save: @escaping @Sendable (_ original: Data, _ refreshed: Data) -> Void = { _, _ in }
        ) {
            self.label = label
            self.save = save
        }
    }

    /// Successful resolution result. `didRefresh` distinguishes a healthy
    /// cache hit from a stale + recreated bookmark — callers can log /
    /// surface UI accordingly.
    struct Resolved: Sendable {
        let url: URL
        let bookmarkData: Data
        let didRefresh: Bool
    }

    enum Failure: Error, LocalizedError, Sendable {
        /// No bookmark was stored — user hasn't granted access yet.
        case missing
        /// Bookmark resolution itself threw (file deleted, sandbox revoked,
        /// bookmark data corrupted).
        case resolutionFailed(String)

        var errorDescription: String? {
            switch self {
            case .missing:
                return "No bookmark is stored for this resource."
            case .resolutionFailed(let reason):
                return "Failed to resolve bookmark: \(reason)"
            }
        }
    }

    /// Injection seam — production uses `.live`; tests construct their own.
    let resolveData: @Sendable (Data) throws -> (URL, Bool)
    let refreshData: @Sendable (URL) throws -> Data

    /// Resolves the stored bookmark with security scope, detecting and
    /// transparently refreshing stale bookmarks. Returned `Resolved.url`
    /// is NOT scope-active — caller must use `withScopedAccess` (or call
    /// `startAccessingSecurityScopedResource` directly) before any file
    /// I/O on it.
    ///
    /// Behaviour:
    /// - `nil` input → `.missing`
    /// - resolve throws → `.resolutionFailed`
    /// - `isStale == false` → `.success` with input data
    /// - `isStale == true` + refresh succeeds → `.success` with new data, target.save invoked
    /// - `isStale == true` + refresh fails → `.success` with input data (one-shot grace),
    ///   logged so the next failure surfaces in the log file
    func resolve(_ data: Data?, target: Target) -> Result<Resolved, Failure> {
        guard let data else {
            return .failure(.missing)
        }

        let url: URL
        let isStale: Bool
        do {
            (url, isStale) = try resolveData(data)
        } catch {
            Logger.warning(
                "[bookmark/\(target.label)] resolve failed: \(error.localizedDescription)",
                category: .fileAccess
            )
            return .failure(.resolutionFailed(error.localizedDescription))
        }

        guard isStale else {
            return .success(Resolved(url: url, bookmarkData: data, didRefresh: false))
        }

        // Stale — try to recreate. Apple recommends starting the scope so
        // bookmarkData can read the URL's resource values; balanced stop on
        // exit. Refresh failure isn't fatal: the URL is still good for THIS
        // run via Apple's grace, so we return the existing data and let the
        // next launch surface re-grant if it really cannot recover.
        var refreshedData: Data?
        Self.withScopedAccess(url) { _ in
            do {
                let fresh = try refreshData(url)
                refreshedData = fresh
                target.save(data, fresh)
                Logger.info(
                    "[bookmark/\(target.label)] was stale; refreshed in place",
                    category: .fileAccess
                )
            } catch {
                Logger.warning(
                    "[bookmark/\(target.label)] stale and refresh failed: \(error.localizedDescription) — current URL still usable but re-grant may be needed next launch",
                    category: .fileAccess
                )
            }
        }

        // Return the refreshed bookmark so in-process callers that copy
        // `bookmarkData` into their own state (e.g. `DiscoveredProject`)
        // don't continue circulating the stale blob and burn another grace
        // use. Falls back to the input on refresh failure.
        return .success(Resolved(
            url: url,
            bookmarkData: refreshedData ?? data,
            didRefresh: refreshedData != nil
        ))
    }

    /// Runs `work` with security scope started; the stop call is balanced
    /// in `defer` even if `work` throws. Returns the closure's result; the
    /// passed-in `Bool` tells the closure whether scope actually started
    /// (some URLs inside the app container resolve fine without it).
    @discardableResult
    static func withScopedAccess<R>(
        _ url: URL,
        _ work: (Bool) throws -> R
    ) rethrows -> R {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return try work(didStart)
    }
}

extension SecurityScopedBookmarkResolver {
    /// Production resolver — wraps Foundation's bookmark APIs directly.
    static let live = SecurityScopedBookmarkResolver(
        resolveData: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        },
        refreshData: { url in
            try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    )

    /// Shorthand for the live resolver; equivalent to `.live`.
    static var shared: SecurityScopedBookmarkResolver { .live }
}

// MARK: - Typed targets

/// One `Target` per persistence destination. Adding a new bookmark kind is
/// the only code change required to plug it into the resolver — call sites
/// then become `SecurityScopedBookmarkResolver.shared.resolve(data, target: .myKind)`.
extension SecurityScopedBookmarkResolver.Target {
    /// Workshop library root — the user-granted `~/Documents/Live Wallpapers/<appid>/`
    /// folder scanned for WPE projects.
    static var workshopLibraryRoot: Self {
        Self(label: "workshopLibraryRoot") { original, refreshed in
            Task { @MainActor in
                guard SettingsManager.shared.loadWorkshopLibraryRootBookmark() == original else {
                    Logger.info(
                        "[bookmark/workshopLibraryRoot] skipped stale refresh save — stored bookmark changed between resolve and save",
                        category: .fileAccess
                    )
                    return
                }
                SettingsManager.shared.saveWorkshopLibraryRootBookmark(refreshed)
            }
        }
    }

    /// Wallpaper Engine install root — the directory containing `assets/`
    /// the user authorised so the renderer can fall back to engine builtins.
    static var wpeEngineAssets: Self {
        Self(label: "wpeEngineAssets") { original, refreshed in
            Task { @MainActor in
                guard SettingsManager.shared.loadWPEEngineAssetsBookmark() == original else {
                    Logger.info(
                        "[bookmark/wpeEngineAssets] skipped stale refresh save — stored bookmark changed between resolve and save",
                        category: .fileAccess
                    )
                    return
                }
                SettingsManager.shared.saveWPEEngineAssetsBookmark(refreshed)
            }
        }
    }

    /// Apple Aerials wallpaper library directory.
    static var aerialsDirectory: Self {
        Self(label: "aerialsDirectory") { original, refreshed in
            Task { @MainActor in
                guard SettingsManager.shared.loadAerialsDirectoryBookmark() == original else {
                    Logger.info(
                        "[bookmark/aerialsDirectory] skipped stale refresh save — stored bookmark changed between resolve and save",
                        category: .fileAccess
                    )
                    return
                }
                SettingsManager.shared.saveAerialsDirectoryBookmark(refreshed)
            }
        }
    }

    /// Read-only one-shot resolution where no persistence is wanted
    /// (e.g. previewing a thumbnail, validating that a path still exists).
    /// Future regressions where someone forgets to plumb a typed target
    /// should be flagged in review.
    static var transient: Self {
        Self(label: "transient")
    }
}
