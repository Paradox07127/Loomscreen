#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Lightweight per-load stage profiler. It records monotonic timestamps at the
/// stage breadcrumbs the renderer already emits via `debugStage`, and once the
/// first frame is done logs one compact per-phase breakdown line — so scene load
/// cost can be measured and compared (e.g. before/after the pipeline cache).
///
/// Opt-in via the `WPEMetalLoadTiming` UserDefault (Developer Tools → "Load
/// timing"); the renderer only allocates a probe when it is set, so a normal run
/// pays nothing. Independent of the scene-debug switch so timing can be gathered
/// without the PNG/shader dump machinery.
///
/// Phase durations pair every stage `X` with its `X.done` marker. Sub-event
/// markers without a `.done` counterpart (`pipeline.pass`, `particle`,
/// `tex.lazy.*`) are sub-steps of a phase and are ignored in the summary.
final class WPESceneLoadTiming {
    static let defaultsKey = "WPEMetalLoadTiming"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The stage whose marker closes the load window and triggers the summary.
    /// Markers recorded after it (e.g. the playback `heartbeat`) are ignored.
    static let terminalStage = "render.firstFrame.done"

    private let workshopID: String
    private let clock: () -> DispatchTime
    private var marks: [(stage: String, time: DispatchTime)] = []
    private var emitted = false

    init(workshopID: String, clock: @escaping () -> DispatchTime = { DispatchTime.now() }) {
        self.workshopID = workshopID
        self.clock = clock
    }

    func mark(_ stage: String) {
        guard !emitted else { return }
        marks.append((stage, clock()))
        if stage == Self.terminalStage {
            emitted = true
            if let summary = Self.summarize(workshopID: workshopID, marks: marks) {
                Logger.notice(summary, category: .performance)
            }
        }
    }

    /// Returns nil when there is nothing to report.
    static func summarize(workshopID: String, marks: [(stage: String, time: DispatchTime)]) -> String? {
        guard let first = marks.first?.time, let last = marks.last?.time, marks.count > 1 else {
            return nil
        }
        // First occurrence of each stage name (a phase's begin/done are unique;
        // repeated sub-event markers collapse to their first sighting).
        var firstSeen: [String: DispatchTime] = [:]
        for mark in marks where firstSeen[mark.stage] == nil {
            firstSeen[mark.stage] = mark.time
        }
        var phases: [(stage: String, ms: Double)] = []
        for (stage, begin) in firstSeen where !stage.hasSuffix(".done") {
            guard let done = firstSeen["\(stage).done"] else { continue }
            phases.append((stage, milliseconds(from: begin, to: done)))
        }
        phases.sort { $0.ms > $1.ms }
        let breakdown = phases.map { "\($0.stage)=\(format($0.ms))ms" }.joined(separator: " ")
        let total = format(milliseconds(from: first, to: last))
        return "[load-timing] scene=\(workshopID) total=\(total)ms | \(breakdown)"
    }

    private static func milliseconds(from a: DispatchTime, to b: DispatchTime) -> Double {
        Double(b.uptimeNanoseconds &- a.uptimeNanoseconds) / 1_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
#endif
