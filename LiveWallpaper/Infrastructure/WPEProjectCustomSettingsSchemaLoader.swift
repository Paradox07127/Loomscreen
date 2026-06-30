import Foundation
import LiveWallpaperCore

#if !LITE_BUILD
final class WPECustomSettingsLoadTiming: @unchecked Sendable {
    static let defaultsKey = "WPECustomSettingsLoadTiming"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private let kind: String
    private let workshopID: String
    private let enabled: Bool
    private let lock = NSLock()
    private var marks: [(stage: String, time: DispatchTime)] = []

    init(kind: String, workshopID: String, enabled: Bool? = nil) {
        self.kind = kind
        self.workshopID = workshopID
        self.enabled = enabled ?? WPECustomSettingsLoadTiming.isEnabled
        mark("begin")
    }

    func mark(_ stage: String) {
        guard enabled else { return }
        lock.lock()
        marks.append((stage: stage, time: .now()))
        lock.unlock()
    }

    func append(to log: String) -> String {
        guard let summary else { return log }
        return "\(log) | \(summary)"
    }

    private var summary: String? {
        lock.lock()
        let snapshot = marks
        lock.unlock()
        guard let first = snapshot.first, let last = snapshot.last, snapshot.count > 1 else {
            return nil
        }
        let total = Self.milliseconds(from: first.time, to: last.time)
        let phases = zip(snapshot, snapshot.dropFirst())
            .map { pair in
                let previous = pair.0
                let current = pair.1
                return "\(current.stage)=\(Self.format(Self.milliseconds(from: previous.time, to: current.time)))ms"
            }
            .joined(separator: " ")
        return "[custom-settings-timing] kind=\(kind) workshop=\(workshopID) total=\(Self.format(total))ms \(phases)"
    }

    private static func milliseconds(from a: DispatchTime, to b: DispatchTime) -> Double {
        Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

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
        let timing = WPECustomSettingsLoadTiming(kind: "html", workshopID: workshopID)
        guard case .folder(let bookmarkData, let indexFileName) = source else {
            return Outcome(
                schema: nil,
                log: "skip - HTML source is not a folder (kind=\(sourceKind(source)))",
                isExpectedAbsence: true
            )
        }

        return await Task.detached(priority: .utility) {
            timing.mark("bookmark.resolve.begin")
            let result = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            )
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
                    if parsed.hasMeaningfulSettings {
                        return timed(Outcome(
                            schema: parsed,
                            log: "loaded \(parsed.properties.count) properties (editable=\(parsed.properties.filter { $0.type.isEditable }.count)) for workshop=\(workshopID), index=\(indexFileName) at \(resolved.url.path)",
                            isExpectedAbsence: false
                        ), timing: timing)
                    } else {
                        return timed(Outcome(
                            schema: nil,
                            log: "parsed \(parsed.properties.count) properties but none are editable for workshop=\(workshopID) at \(resolved.url.path)",
                            isExpectedAbsence: true
                        ), timing: timing)
                    }
                } catch {
                    timing.mark("schema.read.failed")
                    return timed(Outcome(
                        schema: nil,
                        log: "project.json read/parse failed for workshop=\(workshopID) at \(resolved.url.path) (\(error.localizedDescription))",
                        isExpectedAbsence: true
                    ), timing: timing)
                }
            }
        }.value
    }

    private static func timed(_ outcome: Outcome, timing: WPECustomSettingsLoadTiming) -> Outcome {
        timing.mark("done")
        return Outcome(
            schema: outcome.schema,
            log: timing.append(to: outcome.log),
            isExpectedAbsence: outcome.isExpectedAbsence
        )
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
