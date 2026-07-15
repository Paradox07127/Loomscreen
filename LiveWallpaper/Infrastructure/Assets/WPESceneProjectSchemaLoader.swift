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

        return await Task.detached(priority: .userInitiated) {
            if let supportRoot,
               let outcome = readFromCache(
                   supportRoot: supportRoot,
                   cacheRelativePath: cacheRelativePath,
                   workshopID: workshopID
               ) {
                return outcome
            }

            guard let bookmark = wpeOrigin?.sourceFolderBookmark else {
                return Outcome(
                    schema: nil,
                    log: "no cached project.json and wpeOrigin missing source bookmark for workshop=\(workshopID)",
                    isExpectedAbsence: false
                )
            }
            return readFromBookmark(bookmark: bookmark, workshopID: workshopID)
        }.value
    }

    // MARK: - Cache path

    private static func readFromCache(
        supportRoot: URL,
        cacheRelativePath: String,
        workshopID: String
    ) -> Outcome? {
        let folderURL = supportRoot
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent(cacheRelativePath, isDirectory: true)
        let projectURL = folderURL.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            return nil
        }
        do {
            // schemecolor is the WPE GLOBAL accent — most scenes never bind a
            // field to it, so the picker is a no-op for them on macOS. Hidden by
            // default (matches read()'s default); scenes that DO reference it via
            // a `{"user":"schemecolor"}` envelope still resolve its value through
            // effectiveSceneValues in the renderer.
            let parsed = try WallpaperEngineProjectPropertySchema.read(from: folderURL)
            return makeOutcome(parsed: parsed, workshopID: workshopID, locationDescription: "cache at \(folderURL.path)")
        } catch {
            return Outcome(
                schema: nil,
                log: "project.json read/parse failed for workshop=\(workshopID) at \(folderURL.path) (\(error.localizedDescription))",
                isExpectedAbsence: true
            )
        }
    }

    // MARK: - Source-bookmark fallback

    private static func readFromBookmark(
        bookmark: Data,
        workshopID: String
    ) -> Outcome {
        let result = SecurityScopedBookmarkResolver.shared.resolve(bookmark, target: .transient)
        switch result {
        case .failure(let failure):
            return Outcome(
                schema: nil,
                log: "bookmark resolve failed for workshop=\(workshopID) (\(failure.localizedDescription))",
                isExpectedAbsence: false
            )
        case .success(let resolved):
            do {
                let parsed = try SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                    try WallpaperEngineProjectPropertySchema.read(from: resolved.url)
                }
                return makeOutcome(parsed: parsed, workshopID: workshopID, locationDescription: "source folder at \(resolved.url.path)")
            } catch {
                return Outcome(
                    schema: nil,
                    log: "project.json read/parse failed for workshop=\(workshopID) at \(resolved.url.path) (\(error.localizedDescription))",
                    isExpectedAbsence: true
                )
            }
        }
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
