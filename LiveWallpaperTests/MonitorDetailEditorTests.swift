import Foundation
import Testing
@testable import LiveWallpaper
@testable import LiveWallpaperCore

@Suite("Monitor v2 inspector editor")
struct MonitorDetailEditorTests {

    private func processes(_ options: [String: MonitorWidgetOptionValue] = [:]) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: .processes, size: .medium, options: options)
    }

    @Test("Process count defaults to 5 and round-trips as a number")
    func processCountDefaultAndRoundTrip() {
        let base = processes()
        #expect(MonitorWidgetDraft.processCount(base) == MonitorWidgetDraft.defaultProcessCount)

        let set = MonitorWidgetDraft.settingProcessCount(3, on: base)
        #expect(set.options[MonitorWidgetDraft.countKey] == .number(3))
        #expect(MonitorWidgetDraft.processCount(set) == 3)
    }

    @Test("Process count is clamped to 1…12 on read and on write")
    func processCountClamped() {
        #expect(MonitorWidgetDraft.processCount(MonitorWidgetDraft.settingProcessCount(99, on: processes())) == 12)
        #expect(MonitorWidgetDraft.processCount(MonitorWidgetDraft.settingProcessCount(0, on: processes())) == 1)
        #expect(MonitorWidgetDraft.processCount(processes([MonitorWidgetDraft.countKey: .number(42)])) == 12)
    }

    @Test("Setting an option never disturbs the placement identity, kind, size, or position")
    func mutationsPreserveIdentity() {
        let base = MonitorWidgetPlacement(kind: .processes, size: .medium, x: 0.25, y: 0.5)
        let mutated = MonitorWidgetDraft.settingProcessCount(7, on: base)
        #expect(mutated.id == base.id)
        #expect(mutated.kind == base.kind)
        #expect(mutated.size == base.size)
        #expect(mutated.x == base.x)
        #expect(mutated.y == base.y)
    }

    @Test("ReduceMotionChoice maps to and from the optional override")
    func reduceMotionTriState() {
        #expect(ReduceMotionChoice(nil) == .system)
        #expect(ReduceMotionChoice(true) == .on)
        #expect(ReduceMotionChoice(false) == .off)

        #expect(ReduceMotionChoice.system.override == nil)
        #expect(ReduceMotionChoice.on.override == true)
        #expect(ReduceMotionChoice.off.override == false)
    }

    @Test("Refresh-rate label clamps the value into 0.2…2 Hz")
    func refreshRateLabelClamps() {
        #expect(MonitorDetailView.refreshHzLabel(1.0) == "1.0 Hz")
        #expect(MonitorDetailView.refreshHzLabel(5.0) == "2.0 Hz")
        #expect(MonitorDetailView.refreshHzLabel(0.05) == "0.2 Hz")
    }

    @Test("Every widget kind has an inspector-list icon")
    func everyKindHasIcon() {
        for kind in MonitorWidgetKind.allCases {
            #expect(!MonitorWidgetFactory.icon(kind).isEmpty)
        }
    }
}
