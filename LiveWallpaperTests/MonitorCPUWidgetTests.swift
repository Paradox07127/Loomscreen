import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class MonitorCPUWidgetTests: XCTestCase {

    func testCompositionPercentsMirrorMock() {
        let (u, s, idle) = MonitorCPUWidgetView.compositionPercents(user: 0.26, system: 0.11)
        XCTAssertEqual(u, 26)
        XCTAssertEqual(s, 11)
        XCTAssertEqual(idle, 63)
        XCTAssertEqual(u + s + idle, 100)
    }

    func testCompositionPercentsNeverNegativeIdle() {
        let (_, _, idle) = MonitorCPUWidgetView.compositionPercents(user: 0.7, system: 0.6)
        XCTAssertEqual(idle, 0)
    }

    func testIdentityLineComposesDynamicGroups() {
        let info = MonitorCPUInfo(
            deviceName: "Apple M5 Pro",
            coreCount: 18,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Super", physicalCount: 6),
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 12)
            ]
        )
        let identity = MonitorCPUWidgetView.identityLine(info)
        XCTAssertEqual(identity?.deviceName, "Apple M5 Pro")
        XCTAssertEqual(identity?.coreSummary, "18 cores (6 Super + 12 Performance)")
    }

    func testIdentityLineUsesRealGroupNamesNotHardcodedPE() {
        let info = MonitorCPUInfo(
            deviceName: "Apple M1",
            coreCount: 8,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 4),
                MonitorCPUCoreGroup(name: "Efficiency", physicalCount: 4)
            ]
        )
        let identity = MonitorCPUWidgetView.identityLine(info)
        XCTAssertEqual(identity?.coreSummary, "8 cores (4 Performance + 4 Efficiency)")
    }

    func testIdentityLineNilWhenInfoAbsent() {
        XCTAssertNil(MonitorCPUWidgetView.identityLine(nil))
    }

    func testIdentityLineDeviceOnlyWhenNoGroups() {
        let info = MonitorCPUInfo(deviceName: "Apple M2", coreCount: nil, coreGroups: nil)
        let identity = MonitorCPUWidgetView.identityLine(info)
        XCTAssertEqual(identity?.deviceName, "Apple M2")
        XCTAssertNil(identity?.coreSummary)
    }

    func testCoreGroupLoadsSlicesByPhysicalCount() {
        let perCore = (0..<18).map { Double($0) / 18.0 }
        let info = MonitorCPUInfo(
            deviceName: nil,
            coreCount: 18,
            coreGroups: [
                MonitorCPUCoreGroup(name: "Super", physicalCount: 6),
                MonitorCPUCoreGroup(name: "Performance", physicalCount: 12)
            ]
        )
        let groups = MonitorCPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: info)
        XCTAssertEqual(groups?.count, 2)
        XCTAssertEqual(groups?[0].name, "Super")
        XCTAssertEqual(groups?[0].loads.count, 6)
        XCTAssertEqual(groups?[1].name, "Performance")
        XCTAssertEqual(groups?[1].loads.count, 12)
        XCTAssertEqual(groups?[0].loads.last, 5.0 / 18.0)
        XCTAssertEqual(groups?[1].loads.first, 6.0 / 18.0)
    }

    func testCoreGroupLoadsNilWhenNoPerCore() {
        let info = MonitorCPUInfo(deviceName: nil, coreCount: 8, coreGroups: nil)
        XCTAssertNil(MonitorCPUWidgetView.coreGroupLoads(perCore: nil, cpuInfo: info))
        XCTAssertNil(MonitorCPUWidgetView.coreGroupLoads(perCore: [], cpuInfo: info))
    }

    func testCoreGroupLoadsFallsBackToSingleGroupWithoutTopology() {
        let perCore = [0.1, 0.2, 0.3, 0.4]
        let groups = MonitorCPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: nil)
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?[0].name, "CPU")
        XCTAssertEqual(groups?[0].loads, perCore)
    }

    func testCoreGroupLoadsHandlesTopologyDrift() {
        let perCore = [0.1, 0.2, 0.3, 0.4, 0.5]
        let info = MonitorCPUInfo(
            deviceName: nil, coreCount: 4,
            coreGroups: [MonitorCPUCoreGroup(name: "Super", physicalCount: 4)]
        )
        let groups = MonitorCPUWidgetView.coreGroupLoads(perCore: perCore, cpuInfo: info)
        XCTAssertEqual(groups?.count, 2)
        XCTAssertEqual(groups?[0].loads.count, 4)
        XCTAssertEqual(groups?[1].name, "CPU")
        XCTAssertEqual(groups?[1].loads, [0.5])
    }

    func testWholePercentRoundsAndClamps() {
        XCTAssertEqual(MonitorCPUWidgetView.wholePercent(0.374), "37%")
        XCTAssertEqual(MonitorCPUWidgetView.wholePercent(1.4), "100%")
        XCTAssertEqual(MonitorCPUWidgetView.wholePercent(-0.2), "0%")
    }

    func testWholeNumberRoundsAndClampsWithoutPercentSign() {
        XCTAssertEqual(MonitorCPUWidgetView.wholeNumber(0.374), "37")
        XCTAssertEqual(MonitorCPUWidgetView.wholeNumber(1.4), "100")
        XCTAssertEqual(MonitorCPUWidgetView.wholeNumber(-0.2), "0")
        XCTAssertFalse(MonitorCPUWidgetView.wholeNumber(0.5).contains("%"))
    }

    func testTemperatureWordThresholds() {
        XCTAssertEqual(MonitorCPUWidgetView.temperatureWord(42), "cool")
        XCTAssertEqual(MonitorCPUWidgetView.temperatureWord(48), "warm")
        XCTAssertEqual(MonitorCPUWidgetView.temperatureWord(58), "hot")
    }

    func testCpuTextRoundsAndClamps() {
        XCTAssertEqual(MonitorCPUWidgetView.cpuText(52.4), "52")
        XCTAssertEqual(MonitorCPUWidgetView.cpuText(0.44), "0.4")
        XCTAssertEqual(MonitorCPUWidgetView.cpuText(3.24), "3.2")
        XCTAssertEqual(MonitorCPUWidgetView.cpuText(9.96), "10.0")
        XCTAssertEqual(MonitorCPUWidgetView.cpuText(-3), "0.0")
    }

    func testBarFractionRelativeToBusiest() {
        XCTAssertEqual(MonitorCPUWidgetView.barFraction(26, maxCPU: 52), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MonitorCPUWidgetView.barFraction(80, maxCPU: 52), 1)
        XCTAssertEqual(MonitorCPUWidgetView.barFraction(10, maxCPU: 0), 1)
    }

    func testLoadTextSingleUsesLoadAverage1() {
        var sys = MonitorSystemSnapshot()
        sys.loadAverage1 = 3.42
        XCTAssertEqual(MonitorCPUWidgetView.loadText(system: sys, triple: false), "3.42")
    }

    func testLoadTextTripleJoinsFirstThree() {
        var sys = MonitorSystemSnapshot()
        sys.cpuLoadAvg = [3.42, 2.88, 2.41]
        XCTAssertEqual(MonitorCPUWidgetView.loadText(system: sys, triple: true), "3.42 · 2.88 · 2.41")
    }

    func testLoadTextTripleFallsBackToSingleWhenNoTriple() {
        var sys = MonitorSystemSnapshot()
        sys.loadAverage1 = 1.5
        XCTAssertEqual(MonitorCPUWidgetView.loadText(system: sys, triple: true), "1.50")
    }

    func testLoadTextNilWhenNothingReported() {
        XCTAssertNil(MonitorCPUWidgetView.loadText(system: MonitorSystemSnapshot(), triple: false))
        XCTAssertNil(MonitorCPUWidgetView.loadText(system: nil, triple: true))
    }

    func testTopCPUProcessesSortsDescendingStableAndCaps() {
        let procs = [
            MonitorProcessSample(name: "A", cpuPercent: 12, memBytes: 0),
            MonitorProcessSample(name: "B", cpuPercent: 52, memBytes: 0),
            MonitorProcessSample(name: "C", cpuPercent: 23, memBytes: 0),
            MonitorProcessSample(name: "D", cpuPercent: 23, memBytes: 0)
        ]
        let top = MonitorCPUWidgetView.topCPUProcesses(procs, limit: 3)
        XCTAssertEqual(top?.map(\.name), ["B", "C", "D"])
    }

    func testTopCPUProcessesNilWhenNoData() {
        XCTAssertNil(MonitorCPUWidgetView.topCPUProcesses(nil, limit: 4))
        XCTAssertNil(MonitorCPUWidgetView.topCPUProcesses([], limit: 4))
    }

    func testCoreCountAndGroupSummary() {
        let groups = [
            MonitorCPUWidgetView.CoreGroupLoads(name: "Super", loads: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]),
            MonitorCPUWidgetView.CoreGroupLoads(name: "Performance", loads: Array(repeating: 0.2, count: 12))
        ]
        XCTAssertEqual(MonitorCPUWidgetView.coreCountText(groups), "18")
        XCTAssertEqual(MonitorCPUWidgetView.groupSummary(groups), "Super·6 / Performance·12")
    }

    func testHistoryWindowDefaultsPerSize() {
        XCTAssertEqual(MonitorCPUDraft.historyWindow(place(.small)), 30)
        XCTAssertEqual(MonitorCPUDraft.historyWindow(place(.medium)), 60)
        XCTAssertEqual(MonitorCPUDraft.historyWindow(place(.large)), 120)
    }

    func testHistoryWindowExplicitOverrideAndInvalidFallback() {
        let set = MonitorCPUDraft.settingHistoryWindow(120, on: place(.medium))
        XCTAssertEqual(MonitorCPUDraft.historyWindow(set), 120)
        var bogus = place(.medium)
        bogus.options[MonitorCPUDraft.historyWindowKey] = .number(45)
        XCTAssertEqual(MonitorCPUDraft.historyWindow(bogus), 60)
    }

    func testShowTogglesDefaultTrueAndRoundTrip() {
        XCTAssertTrue(MonitorCPUDraft.showHeatmap(place(.medium)))
        XCTAssertTrue(MonitorCPUDraft.showComposition(place(.medium)))
        XCTAssertTrue(MonitorCPUDraft.showSensors(place(.medium)))

        let p = place(.medium)
        XCTAssertFalse(MonitorCPUDraft.showHeatmap(MonitorCPUDraft.settingShowHeatmap(false, on: p)))
        XCTAssertFalse(MonitorCPUDraft.showComposition(MonitorCPUDraft.settingShowComposition(false, on: p)))
        XCTAssertFalse(MonitorCPUDraft.showSensors(MonitorCPUDraft.settingShowSensors(false, on: p)))
    }

    private func place(_ size: MonitorWidgetSize) -> MonitorWidgetPlacement {
        MonitorWidgetPlacement(kind: .cpu, size: size)
    }
}
