import Foundation
import LiveWallpaperCore

#if !LITE_BUILD
enum WPEProjectCustomSettingsSchemaLoader {
    struct Outcome: Sendable {
        let schema: WallpaperEngineProjectPropertySchema?
        let log: String
        let isExpectedAbsence: Bool
    }

    static func load(
        source: HTMLSource?,
        wpeOrigin: WPEOrigin?
    ) async -> Outcome {
        if let wpeOrigin, wpeOrigin.originalType != .web {
            return Outcome(
                schema: nil,
                log: "skip - wpeOrigin type is not .web (origin=\(wpeOrigin.originalType))",
                isExpectedAbsence: true
            )
        }

        return await loadFolderSchema(
            source: source,
            workshopID: wpeOrigin?.workshopID ?? "folder"
        )
    }

    private static func loadFolderSchema(
        source: HTMLSource?,
        workshopID: String
    ) async -> Outcome {
        guard case .folder(let bookmarkData, let indexFileName) = source else {
            return Outcome(
                schema: nil,
                log: "skip - HTML source is not a folder (kind=\(sourceKind(source)))",
                isExpectedAbsence: true
            )
        }

        return await Task.detached(priority: .utility) {
            let result = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            )
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
                    if parsed.hasMeaningfulSettings {
                        return Outcome(
                            schema: parsed,
                            log: "loaded \(parsed.properties.count) properties (editable=\(parsed.properties.filter { $0.type.isEditable }.count)) for workshop=\(workshopID), index=\(indexFileName) at \(resolved.url.path)",
                            isExpectedAbsence: false
                        )
                    } else {
                        return Outcome(
                            schema: nil,
                            log: "parsed \(parsed.properties.count) properties but none are editable for workshop=\(workshopID) at \(resolved.url.path)",
                            isExpectedAbsence: true
                        )
                    }
                } catch {
                    return Outcome(
                        schema: nil,
                        log: "project.json read/parse failed for workshop=\(workshopID) at \(resolved.url.path) (\(error.localizedDescription))",
                        isExpectedAbsence: true
                    )
                }
            }
        }.value
    }

    private static func sourceKind(_ source: HTMLSource?) -> String {
        switch source {
        case .folder: return "folder"
        case .file: return "file"
        case .url: return "url"
        case .inline: return "inline"
        case .none: return "nil"
        }
    }
}
#endif
