#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Resolves the `project.json` schema for a WPE *scene* descriptor.
///
/// The runtime cache (`wpe-cache/<id>/`) only holds what the `scene.pkg`
/// archive shipped — `project.json` lives next to the archive in the workshop
/// folder and is never extracted. Try cache first (a future importer revision
/// may top it up), then fall back to `WPEOrigin.sourceFolderBookmark` so
/// existing caches without a copied `project.json` still show their
/// author-defined properties.
enum WPESceneProjectSchemaLoader {
    struct Outcome: Sendable {
        let schema: WallpaperEngineProjectPropertySchema?
        let log: String
        let isExpectedAbsence: Bool
    }

    static func load(
        descriptor: SceneDescriptor,
        wpeOrigin: WPEOrigin?,
        applicationSupportRootURL: URL? = nil
    ) async -> Outcome {
        guard WPEPathSafety.isSafeCacheRelativePath(descriptor.cacheRelativePath) else {
            return Outcome(
                schema: nil,
                log: "skip - unsafe cacheRelativePath (\(descriptor.cacheRelativePath))",
                isExpectedAbsence: true
            )
        }

        let cacheRelativePath = descriptor.cacheRelativePath
        let supportRoot = applicationSupportRootURL ?? defaultApplicationSupportRoot()
        let workshopID = descriptor.workshopID
        let timing = WPECustomSettingsLoadTiming(kind: "scene", workshopID: workshopID)

        return await Task.detached(priority: .userInitiated) {
            if let supportRoot,
               let outcome = readFromCache(
                   supportRoot: supportRoot,
                   cacheRelativePath: cacheRelativePath,
                   workshopID: workshopID,
                   timing: timing
               ) {
                return outcome
            }

            guard let bookmark = wpeOrigin?.sourceFolderBookmark else {
                return timed(Outcome(
                    schema: nil,
                    log: "no cached project.json and wpeOrigin missing source bookmark for workshop=\(workshopID)",
                    isExpectedAbsence: false
                ), timing: timing)
            }
            return readFromBookmark(bookmark: bookmark, workshopID: workshopID, timing: timing)
        }.value
    }

    // MARK: - Cache path

    private static func readFromCache(
        supportRoot: URL,
        cacheRelativePath: String,
        workshopID: String,
        timing: WPECustomSettingsLoadTiming
    ) -> Outcome? {
        let folderURL = supportRoot
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
        let projectURL = folderURL.appendingPathComponent("project.json")
        timing.mark("cache.probe.begin")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            timing.mark("cache.probe.miss")
            return nil
        }
        timing.mark("cache.probe.hit")
        do {
            // schemecolor is the WPE GLOBAL accent — most scenes never bind a
            // field to it, so the picker is a no-op for them on macOS. Hidden by
            // default (matches read()'s default); scenes that DO reference it via
            // a `{"user":"schemecolor"}` envelope still resolve its value through
            // effectiveSceneValues in the renderer.
            timing.mark("schema.read.begin")
            let parsed = try WallpaperEngineProjectPropertySchema.read(from: folderURL)
            timing.mark("schema.read.done")
            return timed(
                makeOutcome(parsed: parsed, workshopID: workshopID, locationDescription: "cache at \(folderURL.path)"),
                timing: timing
            )
        } catch {
            timing.mark("schema.read.failed")
            return timed(Outcome(
                schema: nil,
                log: "project.json read/parse failed for workshop=\(workshopID) at \(folderURL.path) (\(error.localizedDescription))",
                isExpectedAbsence: true
            ), timing: timing)
        }
    }

    // MARK: - Source-bookmark fallback

    private static func readFromBookmark(
        bookmark: Data,
        workshopID: String,
        timing: WPECustomSettingsLoadTiming
    ) -> Outcome {
        timing.mark("bookmark.resolve.begin")
        let result = SecurityScopedBookmarkResolver.shared.resolve(bookmark, target: .transient)
        timing.mark("bookmark.resolve.done")
        switch result {
        case .failure(let failure):
            return timed(Outcome(
                schema: nil,
                log: "bookmark resolve failed for workshop=\(workshopID) (\(failure.localizedDescription))",
                isExpectedAbsence: false
            ), timing: timing)
        case .success(let resolved):
            do {
                timing.mark("schema.read.begin")
                let parsed = try SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    try WallpaperEngineProjectPropertySchema.read(from: resolved.url)
                }
                timing.mark("schema.read.done")
                return timed(
                    makeOutcome(parsed: parsed, workshopID: workshopID, locationDescription: "source folder at \(resolved.url.path)"),
                    timing: timing
                )
            } catch {
                timing.mark("schema.read.failed")
                return timed(Outcome(
                    schema: nil,
                    log: "project.json read/parse failed for workshop=\(workshopID) at \(resolved.url.path) (\(error.localizedDescription))",
                    isExpectedAbsence: true
                ), timing: timing)
            }
        }
    }

    private static func timed(_ outcome: Outcome, timing: WPECustomSettingsLoadTiming) -> Outcome {
        timing.mark("done")
        return Outcome(
            schema: outcome.schema,
            log: timing.append(to: outcome.log),
            isExpectedAbsence: outcome.isExpectedAbsence
        )
    }

    private static func makeOutcome(
        parsed: WallpaperEngineProjectPropertySchema,
        workshopID: String,
        locationDescription: String
    ) -> Outcome {
        if parsed.hasMeaningfulSettings {
            return Outcome(
                schema: parsed,
                log: "loaded \(parsed.properties.count) properties (editable=\(parsed.properties.filter { $0.type.isEditable }.count)) for workshop=\(workshopID) from \(locationDescription)",
                isExpectedAbsence: false
            )
        }
        return Outcome(
            schema: nil,
            log: "parsed \(parsed.properties.count) properties but none are editable for workshop=\(workshopID) from \(locationDescription)",
            isExpectedAbsence: true
        )
    }

    private static func defaultApplicationSupportRoot() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }
}
#endif
