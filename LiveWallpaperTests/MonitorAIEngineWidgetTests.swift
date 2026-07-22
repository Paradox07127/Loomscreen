import Testing
import Foundation
@testable import LiveWallpaper

struct MonitorAIEngineWidgetTests {

    private func proc(_ name: String, mb: Double) -> MonitorANEProcess {
        MonitorANEProcess(name: name, footprintBytes: UInt64(mb * 1_048_576))
    }

    @Test("display state distinguishes unsampled / idle / active from aneActive")
    func displayState() {
        #expect(MonitorAIEngineWidgetView.displayState(aneActive: nil) == .unsampled)
        #expect(MonitorAIEngineWidgetView.displayState(aneActive: false) == .idle)
        #expect(MonitorAIEngineWidgetView.displayState(aneActive: true) == .active)
    }

    @Test("busiest process is the largest footprint regardless of input order")
    func busiestPick() {
        let list = [proc("A", mb: 88), proc("Whisper", mb: 762), proc("B", mb: 120)]
        #expect(MonitorAIEngineWidgetView.busiestProcess(list)?.name == "Whisper")
    }

    @Test("busiest process is nil for an empty list")
    func busiestEmpty() {
        #expect(MonitorAIEngineWidgetView.busiestProcess([]) == nil)
    }

    @Test("ranked processes are sorted by footprint desc and capped at 5")
    func rankingCap() {
        let list = [
            proc("a", mb: 10), proc("b", mb: 90), proc("c", mb: 50),
            proc("d", mb: 70), proc("e", mb: 30), proc("f", mb: 5),
        ]
        let ranked = MonitorAIEngineWidgetView.rankedProcesses(list)
        #expect(ranked.count == 5)
        #expect(ranked.map(\.name) == ["b", "d", "c", "e", "a"])
    }

    @Test("bar fraction is footprint ÷ top; the top row is full")
    func barFraction() {
        let top: UInt64 = 800
        #expect(MonitorAIEngineWidgetView.barFraction(800, top: top) == 1)
        #expect(MonitorAIEngineWidgetView.barFraction(400, top: top) == 0.5)
        #expect(MonitorAIEngineWidgetView.barFraction(0, top: top) == 0)
    }

    @Test("bar fraction never divides by zero and clamps to 0…1")
    func barFractionGuards() {
        #expect(MonitorAIEngineWidgetView.barFraction(500, top: 0) == 0)
        #expect(MonitorAIEngineWidgetView.barFraction(900, top: 800) == 1)
    }

    @Test("power fraction is watts ÷ the ~8W ceiling, clamped 0…1")
    func powerFraction() {
        #expect(MonitorAIEngineWidgetView.powerFraction(0) == 0)
        #expect(MonitorAIEngineWidgetView.powerFraction(4) == 0.5)
        #expect(MonitorAIEngineWidgetView.powerFraction(8) == 1)
        #expect(MonitorAIEngineWidgetView.powerFraction(12) == 1)
    }

    @Test("footprint splits into a numeric value and a dimmable unit")
    func splitBytes() {
        let parts = MonitorAIEngineWidgetView.splitBytes(UInt64(762 * 1_048_576))
        #expect(parts.value == "762")
        #expect(parts.unit == " MB")
    }
}
