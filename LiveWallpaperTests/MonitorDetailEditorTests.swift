import Foundation
import Testing
@testable import LiveWallpaper
@testable import LiveWallpaperCore

/// Pure-logic coverage for the Monitor v2 inspector editor: the option
/// encode/decode round-trips (`MonitorWidgetDraft`) that back the per-widget
/// settings popover, the reduce-motion tri-state mapping, and the refresh-rate
/// label. No view is instantiated — these pin the data contract the widgets read
/// (`showsSeconds` / `worldClocks` / `count`), verified against the widget views.
@Suite("Monitor v2 inspector editor")
struct MonitorDetailEditorTests {

    private func clock(_ options: [String: MonitorWidgetOptionValue] = [:]) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: .clock, size: .medium, options: options)
    }

    private func processes(_ options: [String: MonitorWidgetOptionValue] = [:]) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: .processes, size: .medium, options: options)
    }

    // MARK: - Clock · showsSeconds

    @Test("showsSeconds defaults to false and round-trips through the option bag")
    func showsSecondsRoundTrip() {
        let base = clock()
        #expect(MonitorWidgetDraft.showsSeconds(base) == false)

        let on = MonitorWidgetDraft.settingShowsSeconds(true, on: base)
        #expect(on.options[MonitorWidgetDraft.showsSecondsKey] == .bool(true))
        #expect(MonitorWidgetDraft.showsSeconds(on) == true)

        let off = MonitorWidgetDraft.settingShowsSeconds(false, on: on)
        #expect(MonitorWidgetDraft.showsSeconds(off) == false)
    }

    // MARK: - Clock · worldClocks

    @Test("worldClocks add/remove round-trips and stores under the widget's key")
    func worldClocksRoundTrip() {
        var placement = clock()
        #expect(MonitorWidgetDraft.worldClocks(placement).isEmpty)

        placement = MonitorWidgetDraft.addingWorldClock("Asia/Tokyo", on: placement)
        placement = MonitorWidgetDraft.addingWorldClock("Europe/London", on: placement)
        #expect(MonitorWidgetDraft.worldClocks(placement) == ["Asia/Tokyo", "Europe/London"])
        #expect(placement.options[MonitorWidgetDraft.worldClocksKey] == .stringList(["Asia/Tokyo", "Europe/London"]))

        placement = MonitorWidgetDraft.removingWorldClock(at: 0, on: placement)
        #expect(MonitorWidgetDraft.worldClocks(placement) == ["Europe/London"])
    }

    @Test("worldClocks is capped at 2 — a third add is a no-op")
    func worldClocksCap() {
        var placement = clock()
        placement = MonitorWidgetDraft.addingWorldClock("Asia/Tokyo", on: placement)
        placement = MonitorWidgetDraft.addingWorldClock("Europe/London", on: placement)
        let before = placement
        placement = MonitorWidgetDraft.addingWorldClock("America/New_York", on: placement)
        #expect(placement == before)
        #expect(MonitorWidgetDraft.worldClocks(placement).count == MonitorWidgetDraft.maxWorldClocks)
    }

    @Test("Adding a duplicate world clock is a no-op")
    func worldClocksNoDuplicates() {
        var placement = clock()
        placement = MonitorWidgetDraft.addingWorldClock("Asia/Tokyo", on: placement)
        let before = placement
        placement = MonitorWidgetDraft.addingWorldClock("Asia/Tokyo", on: placement)
        #expect(placement == before)
    }

    @Test("Removing the last world clock drops the key entirely, not an empty list")
    func worldClocksEmptyDropsKey() {
        var placement = clock()
        placement = MonitorWidgetDraft.addingWorldClock("Asia/Tokyo", on: placement)
        placement = MonitorWidgetDraft.removingWorldClock(at: 0, on: placement)
        #expect(placement.options[MonitorWidgetDraft.worldClocksKey] == nil)
        #expect(MonitorWidgetDraft.worldClocks(placement).isEmpty)
    }

    @Test("A stored worldClocks list longer than the cap reads back clamped")
    func worldClocksStoredOverCapReadsClamped() {
        let placement = clock([
            MonitorWidgetDraft.worldClocksKey: .stringList(["Asia/Tokyo", "Europe/London", "America/New_York"])
        ])
        #expect(MonitorWidgetDraft.worldClocks(placement) == ["Asia/Tokyo", "Europe/London"])
    }

    // MARK: - Processes · count

    @Test("Process count defaults to 5 and round-trips as a number")
    func processCountDefaultAndRoundTrip() {
        let base = processes()
        #expect(MonitorWidgetDraft.processCount(base) == MonitorWidgetDraft.defaultProcessCount)

        let set = MonitorWidgetDraft.settingProcessCount(3, on: base)
        #expect(set.options[MonitorWidgetDraft.countKey] == .number(3))
        #expect(MonitorWidgetDraft.processCount(set) == 3)
    }

    @Test("Process count is clamped to 1…8 on read and on write")
    func processCountClamped() {
        #expect(MonitorWidgetDraft.processCount(MonitorWidgetDraft.settingProcessCount(99, on: processes())) == 8)
        #expect(MonitorWidgetDraft.processCount(MonitorWidgetDraft.settingProcessCount(0, on: processes())) == 1)
        // A raw out-of-range value already in the bag also reads back clamped.
        #expect(MonitorWidgetDraft.processCount(processes([MonitorWidgetDraft.countKey: .number(42)])) == 8)
    }

    @Test("Setting an option never disturbs the placement identity, kind, size, or position")
    func mutationsPreserveIdentity() {
        let base = MonitorWidgetPlacement(kind: .clock, size: .medium, x: 0.25, y: 0.5)
        let mutated = MonitorWidgetDraft.settingShowsSeconds(true, on: base)
        #expect(mutated.id == base.id)
        #expect(mutated.kind == base.kind)
        #expect(mutated.size == base.size)
        #expect(mutated.x == base.x)
        #expect(mutated.y == base.y)
    }

    // MARK: - Reduce-motion tri-state

    @Test("ReduceMotionChoice maps to and from the optional override")
    func reduceMotionTriState() {
        #expect(ReduceMotionChoice(nil) == .system)
        #expect(ReduceMotionChoice(true) == .on)
        #expect(ReduceMotionChoice(false) == .off)

        #expect(ReduceMotionChoice.system.override == nil)
        #expect(ReduceMotionChoice.on.override == true)
        #expect(ReduceMotionChoice.off.override == false)
    }

    // MARK: - Refresh-rate label

    @Test("Refresh-rate label clamps the value into 0.2…2 Hz")
    func refreshRateLabelClamps() {
        #expect(MonitorDetailView.refreshHzLabel(1.0) == "1.0 Hz")
        #expect(MonitorDetailView.refreshHzLabel(5.0) == "2.0 Hz")
        #expect(MonitorDetailView.refreshHzLabel(0.05) == "0.2 Hz")
    }

    // MARK: - Icon coverage

    @Test("Every widget kind has an inspector-list icon")
    func everyKindHasIcon() {
        for kind in MonitorWidgetKind.allCases {
            #expect(!MonitorWidgetFactory.icon(kind).isEmpty)
        }
    }
}
