#if !LITE_BUILD
import Foundation

/// Single source of truth for the app's on-disk WPE storage locations and
/// `du`-style allocated-size accounting. Consolidates container Steam path
/// resolution that was duplicated across the inventory, reclaimer, and download
/// flows. All roots are symlink-resolved and containment-anchored so a symlinked
/// `Steam`/`steamapps`/… can't re-base a path outside the container.
enum WPEStoragePaths {
    /// Wallpaper Engine's Steam app id.
    static let wallpaperEngineAppID = 431960

    /// Container-local Steam root (`<AppSupport>/Steam`), or nil if unresolvable.
    static func containerSteamRoot(fileManager fm: FileManager = .default) -> URL? {
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        let safe = appSupport.standardizedFileURL.resolvingSymlinksInPath()
        let steam = safe
            .appendingPathComponent("Steam", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard WPEPathSafety.contains(steam, in: safe) else { return nil }
        return steam
    }

    /// Container Workshop content root (`…/Steam/steamapps/workshop/content/431960`),
    /// where sandboxed SteamCMD downloads land (STEAMROOT redirected into the
    /// container). nil when unresolvable; an absent folder is normal.
    static func containerWorkshopContentRoot(fileManager fm: FileManager = .default) -> URL? {
        guard let steam = containerSteamRoot(fileManager: fm) else { return nil }
        let content = steam
            .appendingPathComponent("steamapps/workshop/content/\(wallpaperEngineAppID)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard WPEPathSafety.contains(content, in: steam) else { return nil }
        return content
    }

    /// Sum of the allocated (`du`-equivalent) size of every regular file under
    /// `url`. Hidden files skipped.
    static func allocatedBytes(at url: URL, fileManager fm: FileManager = .default) -> UInt64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
#endif
