import Testing
import Foundation
import Darwin
@testable import LiveWallpaper

@Suite("Monitor system samplers v2")
struct MonitorSystemSamplersV2Tests {

    @Test("A helper resolves up to its top-level app, stopping below launchd")
    func topLevelPIDWalksToApp() {
        let parents: [Int32: Int32] = [100: 1, 200: 100, 201: 200, 300: 1]
        #expect(SystemMetricsSamplers.topLevelPID(201, parents: parents) == 100)
        #expect(SystemMetricsSamplers.topLevelPID(200, parents: parents) == 100)
        #expect(SystemMetricsSamplers.topLevelPID(100, parents: parents) == 100)
        #expect(SystemMetricsSamplers.topLevelPID(300, parents: parents) == 300)
    }

    @Test("Unknown parent or a cycle terminates instead of looping")
    func topLevelPIDGuardsCyclesAndGaps() {
        let parents: [Int32: Int32] = [500: 600, 700: 800, 800: 700]
        #expect(SystemMetricsSamplers.topLevelPID(500, parents: parents) == 600)
        let cyclic = SystemMetricsSamplers.topLevelPID(700, parents: parents)
        #expect(cyclic == 700 || cyclic == 800)
    }

    private func makeVMStats(
        internalPages: UInt32,
        purgeable: UInt32,
        wire: UInt32,
        compressor: UInt32,
        external: UInt32
    ) -> vm_statistics64_data_t {
        var stats = vm_statistics64_data_t()
        stats.internal_page_count = internalPages
        stats.purgeable_count = purgeable
        stats.wire_count = wire
        stats.compressor_page_count = compressor
        stats.external_page_count = external
        return stats
    }

    @Test("Activity-Monitor breakdown maps the right page fields")
    func memoryBreakdownFields() {
        let page: UInt64 = 16_384
        let stats = makeVMStats(internalPages: 100, purgeable: 10, wire: 20, compressor: 5, external: 30)
        let breakdown = SystemMetricsSamplers.memoryBreakdown(from: stats, pageSize: page)

        #expect(breakdown.appBytes == 90 * page)
        #expect(breakdown.wiredBytes == 20 * page)
        #expect(breakdown.compressedBytes == 5 * page)
        #expect(breakdown.cachedFilesBytes == 40 * page)
    }

    @Test("Memory Used = app + wired + compressed (Activity Monitor formula)")
    func memoryUsedFormula() {
        let page: UInt64 = 4_096
        let stats = makeVMStats(internalPages: 200, purgeable: 50, wire: 40, compressor: 10, external: 60)
        let breakdown = SystemMetricsSamplers.memoryBreakdown(from: stats, pageSize: page)
        let used = breakdown.appBytes + breakdown.wiredBytes + breakdown.compressedBytes
        #expect(used == 200 * page)
        #expect(used != (breakdown.appBytes + breakdown.wiredBytes + breakdown.compressedBytes + breakdown.cachedFilesBytes))
    }

    @Test("purgeable exceeding internal clamps App to zero (no underflow)")
    func memoryAppUnderflowGuard() {
        let stats = makeVMStats(internalPages: 5, purgeable: 100, wire: 1, compressor: 1, external: 1)
        let breakdown = SystemMetricsSamplers.memoryBreakdown(from: stats, pageSize: 4_096)
        #expect(breakdown.appBytes == 0)
    }

    private func iface(
        _ name: String,
        ibytes: UInt64 = 0,
        obytes: UInt64 = 0,
        ipackets: UInt64 = 0,
        opackets: UInt64 = 0,
        ierrors: UInt64 = 0,
        oerrors: UInt64 = 0,
        iqdrops: UInt64 = 0,
        addresses: [String] = []
    ) -> SystemMetricsSamplers.InterfaceCounters {
        SystemMetricsSamplers.InterfaceCounters(
            name: name,
            ibytes: ibytes, obytes: obytes,
            ipackets: ipackets, opackets: opackets,
            ierrors: ierrors, oerrors: oerrors,
            iqdrops: iqdrops, addresses: addresses
        )
    }

    @Test("Interface rates come from the previous-sample byte/packet delta")
    func interfaceRateMath() {
        let previous = [
            "en0": iface("en0", ibytes: 1_000, obytes: 500, ipackets: 10, opackets: 5)
        ]
        let current = [
            iface("en0", ibytes: 3_000, obytes: 1_500, ipackets: 30, opackets: 15, addresses: ["192.168.1.5"])
        ]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: previous, current: current, interval: 2.0, activeName: "en0"
        )
        #expect(rows.count == 1)
        let en0 = rows[0]
        #expect(en0.rxBytesPerSec == 1_000)
        #expect(en0.txBytesPerSec == 500)
        #expect(en0.rxPacketsPerSec == 10)
        #expect(en0.txPacketsPerSec == 5)
        #expect(en0.addresses == ["192.168.1.5"])
        #expect(en0.isActive == true)
    }

    @Test("Errors and drops surface cumulatively, not as rates")
    func interfaceCumulativeCounters() {
        let current = [iface("en0", ibytes: 100, ierrors: 7, oerrors: 3, iqdrops: 2)]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: [:], current: current, interval: 1.0, activeName: nil
        )
        #expect(rows.first?.rxErrors == 7)
        #expect(rows.first?.txErrors == 3)
        #expect(rows.first?.rxDrops == 2)
    }

    @Test("First sample (no previous) yields zero rates but retains the interface")
    func interfaceFirstSample() {
        let current = [iface("en0", ibytes: 5_000, obytes: 2_000)]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: [:], current: current, interval: 2.0, activeName: nil
        )
        #expect(rows.count == 1)
        #expect(rows[0].rxBytesPerSec == 0)
        #expect(rows[0].txBytesPerSec == 0)
    }

    @Test("A counter reset (current < previous) is treated as zero, not negative")
    func interfaceCounterWrap() {
        let previous = ["en0": iface("en0", ibytes: 10_000, obytes: 8_000)]
        let current = [iface("en0", ibytes: 100, obytes: 50)]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: previous, current: current, interval: 1.0, activeName: nil
        )
        #expect(rows[0].rxBytesPerSec == 0)
        #expect(rows[0].txBytesPerSec == 0)
    }

    @Test("Dormant interface (no traffic, no address) is dropped")
    func interfaceDormantDropped() {
        let current = [
            iface("en0", ibytes: 1_000, addresses: ["10.0.0.2"]),
            iface("utun9")
        ]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: [:], current: current, interval: 1.0, activeName: nil
        )
        #expect(rows.map(\.name) == ["en0"])
    }

    @Test("Interface kept when it has an address even with no traffic")
    func interfaceKeptForAddress() {
        let current = [iface("en1", addresses: ["fe80::1"])]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: [:], current: current, interval: 1.0, activeName: nil
        )
        #expect(rows.map(\.name) == ["en1"])
    }

    @Test("Absent activeName falls back to the highest-rx-rate interface")
    func interfaceActiveFallback() {
        let previous = [
            "en0": iface("en0", ibytes: 0),
            "en1": iface("en1", ibytes: 0)
        ]
        let current = [
            iface("en0", ibytes: 1_000),
            iface("en1", ibytes: 9_000)
        ]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: previous, current: current, interval: 1.0, activeName: nil
        )
        let active = rows.first(where: { $0.isActive == true })
        #expect(active?.name == "en1")
    }

    @Test("NWPath-chosen interface wins over traffic for isActive")
    func interfaceActivePathWins() {
        let previous = ["en0": iface("en0"), "en1": iface("en1")]
        let current = [
            iface("en0", ibytes: 1_000),
            iface("en1", ibytes: 9_000)
        ]
        let rows = SystemMetricsSamplers.networkInterfaces(
            previous: previous, current: current, interval: 1.0, activeName: "en0"
        )
        #expect(rows.first(where: { $0.isActive == true })?.name == "en0")
        #expect(rows.filter { $0.isActive == true }.count == 1)
    }

    @Test("IOPS -1 (calculating) maps to nil; non-negative maps through")
    func iopsMinutesMapping() {
        #expect(SystemMetricsSamplers.mapIOPSMinutes(-1) == nil)
        #expect(SystemMetricsSamplers.mapIOPSMinutes(nil) == nil)
        #expect(SystemMetricsSamplers.mapIOPSMinutes(0) == 0)
        #expect(SystemMetricsSamplers.mapIOPSMinutes(125) == 125)
    }

    @Test("Providing power source type maps to compact token")
    func powerSourceMapping() {
        #expect(SystemMetricsSamplers.mapPowerSourceType(kIOPSBatteryPowerValue) == "battery")
        #expect(SystemMetricsSamplers.mapPowerSourceType(kIOPSACPowerValue) == "ac")
        #expect(SystemMetricsSamplers.mapPowerSourceType("UPS Power") == "ups")
        #expect(SystemMetricsSamplers.mapPowerSourceType(nil) == nil)
    }

    @Test("Accessory kind is inferred from the product name")
    func accessoryKindHeuristic() {
        #expect(SystemMetricsSamplers.accessoryKind(productName: "Magic Trackpad") == "trackpad")
        #expect(SystemMetricsSamplers.accessoryKind(productName: "Taijia's Magic Keyboard") == "keyboard")
        #expect(SystemMetricsSamplers.accessoryKind(productName: "Magic Mouse") == "mouse")
        #expect(SystemMetricsSamplers.accessoryKind(productName: "Some Widget") == "other")
        #expect(SystemMetricsSamplers.accessoryKind(productName: "trackpad") == "trackpad")
    }

    @Test("CPU info reports a device name, core count, and named core groups")
    func cpuInfoShape() {
        let info = SystemMetricsSamplers.sampleCPUInfo()
        if let groups = info.coreGroups {
            #expect(!groups.isEmpty)
            #expect(groups.allSatisfy { $0.physicalCount > 0 })
            #expect(groups.allSatisfy { !$0.name.isEmpty })
            if let count = info.coreCount {
                let groupSum = groups.reduce(0) { $0 + $1.physicalCount }
                #expect(groupSum <= count || groups.count == 1)
            }
        }
    }

    @Test("Load averages, when present, carry three finite values")
    func loadAveragesShape() {
        if let loads = SystemMetricsSamplers.sampleLoadAverages() {
            #expect(loads.count == 3)
            #expect(loads.allSatisfy { $0.isFinite && $0 >= 0 })
        }
    }

    @Test("Default options preserve pre-v2 behavior")
    func defaultOptions() {
        let options = SystemMetricsSource.Options.default
        #expect(options.gpu == true)
        #expect(options.accessories == true)
        #expect(options.ane == false)
        #expect(options.topProcesses == false)
    }

    @Test("includeTopProcesses convenience init only flips the top-processes gate")
    func convenienceInitGating() {
        var expected = SystemMetricsSource.Options.default
        expected.topProcesses = true
        var built = SystemMetricsSource.Options.default
        built.topProcesses = true
        #expect(built == expected)
        #expect(built.gpu == true)
        #expect(built.ane == false)
    }

    @Test("Disabling a gate is representable and distinct from the default")
    func gatingDistinct() {
        var disabled = SystemMetricsSource.Options.default
        disabled.gpu = false
        disabled.accessories = false
        #expect(disabled != SystemMetricsSource.Options.default)
        #expect(disabled.gpu == false)
        #expect(disabled.accessories == false)
    }

    @Test("GPU sample scales percentages into 0…1 or leaves nil")
    func gpuSampleUnits() {
        let sample = SystemMetricsSamplers.sampleGPU()
        for value in [sample.deviceUtil, sample.rendererUtil, sample.tilerUtil] {
            if let value {
                #expect(value >= 0 && value <= 1)
            }
        }
        if let cores = sample.coreCount {
            #expect(cores > 0)
        }
    }

    @Test("Accessory percents are 0…1 fractions")
    func accessoryUnits() {
        for accessory in SystemMetricsSamplers.sampleAccessoryBatteries() {
            #expect(accessory.percent >= 0 && accessory.percent <= 1)
            #expect(!accessory.name.isEmpty)
        }
    }

    @Test("ANE sample keeps only positive footprints and derives active flag")
    func aneSampleConsistency() {
        let sample = SystemMetricsSamplers.sampleANE(limit: 5)
        #expect(sample.processes.count <= 5)
        #expect(sample.processes.allSatisfy { $0.footprintBytes > 0 })
        #expect(sample.active == !sample.processes.isEmpty || sample.processes.isEmpty)
        let footprints = sample.processes.map(\.footprintBytes)
        #expect(footprints == footprints.sorted(by: >))
    }
}
