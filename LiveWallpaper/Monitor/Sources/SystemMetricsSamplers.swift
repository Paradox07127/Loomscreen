import Foundation
import Darwin
import IOKit
import IOKit.ps
import Metal

/// Stateless C-API plumbing behind `SystemMetricsSource`. Every reading is a
/// read-only kernel / IOKit / sysctl query that works inside the App Sandbox; a
/// sampler that finds nothing returns `nil`/`0` rather than throwing, so one dead
/// probe never sinks the whole snapshot. Rate-style samplers take the previous raw
/// counters and the elapsed interval and return a per-second rate.
enum SystemMetricsSamplers {

    // MARK: - CPU (total + per-core)

    struct CPUTicks: Sendable, Equatable {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64
        var total: UInt64 { user &+ system &+ idle &+ nice }
        var busy: UInt64 { user &+ system &+ nice }
    }

    struct CPUSample: Sendable {
        var total: Double
        var user: Double
        var system: Double
        var perCore: [Double]
    }

    struct CPURawCounters: Sendable {
        var aggregate: CPUTicks?
        var perCore: [CPUTicks]
    }

    /// Reads `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` and diffs against the
    /// previous read to get busy-fraction total + per-core. First call (no `previous`)
    /// returns zeros but captures the baseline counters for the next interval.
    static func sampleCPU(previous: CPURawCounters?) -> (sample: CPUSample, counters: CPURawCounters) {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        // `mach_host_self()` returns an owned send right; deallocate it or every
        // poll leaks a port ref for the lifetime of this forever-running sampler.
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &infoArray,
            &infoCount
        )

        guard result == KERN_SUCCESS, let infoArray else {
            let zero = CPUSample(total: 0, user: 0, system: 0, perCore: [])
            return (zero, CPURawCounters(aggregate: nil, perCore: []))
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: infoArray)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var perCoreTicks: [CPUTicks] = []
        perCoreTicks.reserveCapacity(Int(cpuCount))
        var aggUser: UInt64 = 0, aggSys: UInt64 = 0, aggIdle: UInt64 = 0, aggNice: UInt64 = 0

        for core in 0..<Int(cpuCount) {
            let base = core * stride
            let user = UInt64(infoArray[base + Int(CPU_STATE_USER)])
            let system = UInt64(infoArray[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(infoArray[base + Int(CPU_STATE_IDLE)])
            let nice = UInt64(infoArray[base + Int(CPU_STATE_NICE)])
            perCoreTicks.append(CPUTicks(user: user, system: system, idle: idle, nice: nice))
            aggUser &+= user; aggSys &+= system; aggIdle &+= idle; aggNice &+= nice
        }

        let aggregate = CPUTicks(user: aggUser, system: aggSys, idle: aggIdle, nice: aggNice)
        let counters = CPURawCounters(aggregate: aggregate, perCore: perCoreTicks)

        guard let previous, let prevAgg = previous.aggregate else {
            return (CPUSample(total: 0, user: 0, system: 0, perCore: []), counters)
        }

        let (total, user, system) = fraction(current: aggregate, previous: prevAgg)
        var perCore: [Double] = []
        if previous.perCore.count == perCoreTicks.count {
            perCore.reserveCapacity(perCoreTicks.count)
            for index in perCoreTicks.indices {
                perCore.append(fraction(current: perCoreTicks[index], previous: previous.perCore[index]).total)
            }
        }

        return (CPUSample(total: total, user: user, system: system, perCore: perCore), counters)
    }

    private static func fraction(current: CPUTicks, previous: CPUTicks) -> (total: Double, user: Double, system: Double) {
        let totalDelta = Double(current.total &- previous.total)
        guard totalDelta > 0 else { return (0, 0, 0) }
        let busyDelta = Double(current.busy &- previous.busy)
        let userDelta = Double((current.user &+ current.nice) &- (previous.user &+ previous.nice))
        let sysDelta = Double(current.system &- previous.system)
        return (
            clamp01(busyDelta / totalDelta),
            clamp01(userDelta / totalDelta),
            clamp01(sysDelta / totalDelta)
        )
    }

    // MARK: - CPU identity (sampled once; topology is fixed for the boot)

    /// Reads `machdep.cpu.brand_string` + `hw.physicalcpu` + the `hw.perflevelN.*`
    /// topology. Each of `hw.nperflevels` levels contributes a group named by its
    /// real `hw.perflevelN.name` string — these vary by chip generation (M5 Pro:
    /// "Super"/"Performance"; older: "Performance"/"Efficiency") so the name is stored
    /// verbatim rather than forced into a "P"/"E" binary. If the name sysctl is
    /// unavailable (e.g. Intel) a single "CPU" group holds `hw.physicalcpu`. Never
    /// throws — a missing field just drops out.
    static func sampleCPUInfo() -> MonitorCPUInfo {
        let deviceName = sysctlString("machdep.cpu.brand_string")
        let coreCount = sysctlInt("hw.physicalcpu")

        var groups: [MonitorCPUCoreGroup] = []
        if let levels = sysctlInt("hw.nperflevels"), levels > 0 {
            for level in 0..<levels {
                guard let count = sysctlInt("hw.perflevel\(level).physicalcpu"), count > 0,
                      let name = sysctlString("hw.perflevel\(level).name") else { continue }
                groups.append(MonitorCPUCoreGroup(name: name, physicalCount: count))
            }
        }
        if groups.isEmpty, let coreCount, coreCount > 0 {
            groups.append(MonitorCPUCoreGroup(name: "CPU", physicalCount: coreCount))
        }

        return MonitorCPUInfo(
            deviceName: deviceName,
            coreCount: coreCount,
            coreGroups: groups.isEmpty ? nil : groups
        )
    }

    /// All three `getloadavg` values (1 / 5 / 15 min). `nil` when the call fails.
    static func sampleLoadAverages() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        let got = getloadavg(&loads, 3)
        guard got == 3 else { return nil }
        return loads
    }

    // MARK: - Memory

    struct MemorySample: Sendable {
        var usedBytes: UInt64
        var totalBytes: UInt64
        var breakdown: MonitorMemoryBreakdown?
    }

    /// Derives the Activity-Monitor breakdown from a `vm_statistics64` struct + page
    /// size. Extracted so the (page-arithmetic) logic is unit-testable without a live
    /// `host_statistics64` call. All arithmetic is saturating on the page counts.
    ///
    /// - App = internal − purgeable, Wired = wire, Compressed = compressor,
    ///   Cached Files = external + purgeable. "Memory Used" (Activity Monitor) =
    ///   App + Wired + Compressed.
    static func memoryBreakdown(from stats: vm_statistics64_data_t, pageSize: UInt64) -> MonitorMemoryBreakdown {
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let externalPages = UInt64(stats.external_page_count)
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return MonitorMemoryBreakdown(
            appBytes: appPages &* pageSize,
            wiredBytes: UInt64(stats.wire_count) &* pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) &* pageSize,
            cachedFilesBytes: (externalPages &+ purgeablePages) &* pageSize
        )
    }

    static func sampleMemory() -> MemorySample {
        let total = ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        host_page_size(hostPort, &pageSize)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            return MemorySample(usedBytes: 0, totalBytes: total, breakdown: nil)
        }
        let breakdown = memoryBreakdown(from: stats, pageSize: UInt64(pageSize))
        // Activity Monitor's "Memory Used" = App + Wired + Compressed (was previously
        // active + wire + compressor, which never matched the value users see).
        let used = breakdown.appBytes &+ breakdown.wiredBytes &+ breakdown.compressedBytes
        return MemorySample(usedBytes: used, totalBytes: total, breakdown: breakdown)
    }

    // MARK: - Swap (sysctl vm.swapusage)

    static func sampleSwapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        guard result == 0 else { return nil }
        return usage.xsu_used
    }

    // MARK: - GPU (IOKit accelerator)

    struct GPUSample: Sendable {
        var deviceUtil: Double?           // 0…1 — total GPU busy
        var rendererUtil: Double?         // 0…1 — graphics (fragment/vertex)
        var tilerUtil: Double?            // 0…1 — TBDR binning
        var coreCount: Int?
    }

    /// Backward-compatible thin wrapper: total device utilization only.
    static func sampleGPUUsage() -> Double? {
        sampleGPU().deviceUtil
    }

    /// One IOAccelerator registry walk yields device/renderer/tiler utilization
    /// (all three keys live in the same `PerformanceStatistics` dictionary) plus the
    /// `gpu-core-count` property. Each utilization is scaled to 0…1; absent keys stay
    /// `nil` (best-effort — key names shift across driver / chip generations).
    static func sampleGPU() -> GPUSample {
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return GPUSample()
        }
        defer { IOObjectRelease(iterator) }

        var sample = GPUSample()
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(current, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else {
                entry = IOIteratorNext(iterator)
                continue
            }

            if let cores = (dict["gpu-core-count"] as? NSNumber)?.intValue, cores > 0 {
                sample.coreCount = cores
            }

            if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                if let device = perfPercent(perfStats["Device Utilization %"])
                    ?? perfPercent(perfStats["GPU Activity(%)"])
                    ?? perfPercent(perfStats["gpuCoreUtilizationComponent"]) {
                    sample.deviceUtil = device
                }
                if let renderer = perfPercent(perfStats["Renderer Utilization %"]) {
                    sample.rendererUtil = renderer
                }
                if let tiler = perfPercent(perfStats["Tiler Utilization %"]) {
                    sample.tilerUtil = tiler
                }
            }
            entry = IOIteratorNext(iterator)
        }
        return sample
    }

    /// The IOAccelerator utilization values arrive as Int or Double percentages;
    /// normalize either to a clamped 0…1 fraction.
    private static func perfPercent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return clamp01(number.doubleValue / 100.0)
    }

    /// `MTLCreateSystemDefaultDevice().name` — sampled once (constant for the boot).
    static func sampleGPUDeviceName() -> String? {
        MTLCreateSystemDefaultDevice()?.name
    }

    // MARK: - Network (getifaddrs, AF_LINK + AF_INET/AF_INET6)

    /// Raw per-interface `if_data` counters (cumulative since boot) + resolved private
    /// addresses. Rates are derived downstream from previous-sample deltas.
    struct InterfaceCounters: Sendable, Equatable {
        var name: String
        var ibytes: UInt64 = 0
        var obytes: UInt64 = 0
        var ipackets: UInt64 = 0
        var opackets: UInt64 = 0
        var ierrors: UInt64 = 0
        var oerrors: UInt64 = 0
        var iqdrops: UInt64 = 0
        var addresses: [String] = []
    }

    struct NetworkCountersSample: Sendable {
        var rx: UInt64
        var tx: UInt64
        var interfaces: [InterfaceCounters]
    }

    /// Single getifaddrs walk. AF_LINK rows carry the `if_data` byte/packet/error
    /// counters (summed into the aggregate and retained per-interface); AF_INET /
    /// AF_INET6 rows contribute the interface's private textual addresses. Loopback is
    /// skipped. The aggregate rx/tx matches the previous summed-only behavior exactly.
    static func sampleNetworkCounters() -> NetworkCountersSample {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return NetworkCountersSample(rx: 0, tx: 0, interfaces: [])
        }
        defer { freeifaddrs(head) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var byName: [String: InterfaceCounters] = [:]
        var order: [String] = []

        func entry(for name: String) -> Int {
            if let existing = order.firstIndex(of: name) { return existing }
            order.append(name)
            byName[name] = InterfaceCounters(name: name)
            return order.count - 1
        }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            defer { cursor = ifa.ifa_next }

            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_LOOPBACK == 0 else { continue }
            guard let namePtr = ifa.ifa_name else { continue }
            let name = String(cString: namePtr)
            guard let addr = ifa.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_LINK) {
                guard flags & IFF_UP != 0, let dataPtr = ifa.ifa_data else { continue }
                let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                rx &+= UInt64(data.ifi_ibytes)
                tx &+= UInt64(data.ifi_obytes)
                _ = entry(for: name)
                byName[name]?.ibytes = UInt64(data.ifi_ibytes)
                byName[name]?.obytes = UInt64(data.ifi_obytes)
                byName[name]?.ipackets = UInt64(data.ifi_ipackets)
                byName[name]?.opackets = UInt64(data.ifi_opackets)
                byName[name]?.ierrors = UInt64(data.ifi_ierrors)
                byName[name]?.oerrors = UInt64(data.ifi_oerrors)
                byName[name]?.iqdrops = UInt64(data.ifi_iqdrops)
            } else if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                if let text = interfaceAddressText(addr, family: family) {
                    _ = entry(for: name)
                    byName[name]?.addresses.append(text)
                }
            }
        }

        let interfaces = order.compactMap { byName[$0] }
        return NetworkCountersSample(rx: rx, tx: tx, interfaces: interfaces)
    }

    /// Numeric textual form of an AF_INET / AF_INET6 sockaddr (getnameinfo,
    /// NI_NUMERICHOST). IPv6 link-local scope suffixes (`%en0`) are trimmed for a
    /// cleaner display value; nil on any resolution failure.
    private static func interfaceAddressText(_ addr: UnsafeMutablePointer<sockaddr>, family: UInt8) -> String? {
        let length = family == UInt8(AF_INET)
            ? socklen_t(MemoryLayout<sockaddr_in>.size)
            : socklen_t(MemoryLayout<sockaddr_in6>.size)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(addr, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard result == 0 else { return nil }
        let bytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        if let percent = text.firstIndex(of: "%") {
            return String(text[text.startIndex..<percent])
        }
        return text.isEmpty ? nil : text
    }

    /// Builds `MonitorNetworkInterface` rows from a previous/current counter pair.
    /// Rates come from byte/packet deltas over the interval; errors/drops are surfaced
    /// cumulatively. Interfaces with no traffic *and* no cumulative counters *and* no
    /// address are dropped (dormant), so the list stays to real, interesting links.
    /// `activeName` (from NWPath) marks `isActive`; when absent the highest-rx-rate
    /// interface is chosen as a fallback.
    static func networkInterfaces(
        previous: [String: InterfaceCounters],
        current: [InterfaceCounters],
        interval: TimeInterval,
        activeName: String?
    ) -> [MonitorNetworkInterface] {
        var rows: [MonitorNetworkInterface] = []
        var bestFallback: (name: String, rx: Double)?

        for counters in current {
            let prev = previous[counters.name]
            let rxRate = rate(current: counters.ibytes, previous: prev?.ibytes ?? counters.ibytes, interval: interval)
            let txRate = rate(current: counters.obytes, previous: prev?.obytes ?? counters.obytes, interval: interval)
            let rxPk = rate(current: counters.ipackets, previous: prev?.ipackets ?? counters.ipackets, interval: interval)
            let txPk = rate(current: counters.opackets, previous: prev?.opackets ?? counters.opackets, interval: interval)

            let hasTraffic = counters.ibytes > 0 || counters.obytes > 0
            let hasAddress = !counters.addresses.isEmpty
            guard hasTraffic || hasAddress else { continue }

            if bestFallback == nil || rxRate > bestFallback!.rx {
                bestFallback = (counters.name, rxRate)
            }

            rows.append(MonitorNetworkInterface(
                name: counters.name,
                rxBytesPerSec: rxRate,
                txBytesPerSec: txRate,
                rxPacketsPerSec: rxPk,
                txPacketsPerSec: txPk,
                rxErrors: counters.ierrors,
                txErrors: counters.oerrors,
                rxDrops: counters.iqdrops,
                addresses: counters.addresses.isEmpty ? nil : counters.addresses,
                isActive: nil
            ))
        }

        let chosen = activeName ?? bestFallback?.name
        if let chosen, let index = rows.firstIndex(where: { $0.name == chosen }) {
            rows[index].isActive = true
        }
        return rows
    }

    // MARK: - Disk (IOBlockStorageDriver Statistics)

    /// Summed bytes-read / bytes-written across every IOBlockStorageDriver. Paired
    /// with the previous read for a per-second rate (wrap → 0).
    static func sampleDiskCounters() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }

            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(current, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                if let bytes = stats["Bytes (Read)"] as? NSNumber { read &+= bytes.uint64Value }
                if let bytes = stats["Bytes (Write)"] as? NSNumber { written &+= bytes.uint64Value }
            }
            entry = IOIteratorNext(iterator)
        }
        return (read, written)
    }

    // MARK: - Battery (IOKit.ps)

    struct BatterySample: Sendable {
        var level: Double
        var charging: Bool
        var isCharged: Bool?
        /// Minutes; IOPS returns -1 for "still calculating" → mapped to nil.
        var minutesRemaining: Double?
        var minutesToFull: Double?
    }

    struct PowerSample: Sendable {
        var battery: BatterySample?
        /// "battery" | "ac" | "ups" — from IOPSGetProvidingPowerSourceType.
        var powerSource: String?
        var lowPowerMode: Bool
    }

    /// -1 (or negative) IOPS time estimate ⇒ "calculating" ⇒ nil. Otherwise minutes.
    static func mapIOPSMinutes(_ raw: Int?) -> Double? {
        guard let raw, raw >= 0 else { return nil }
        return Double(raw)
    }

    /// Maps the IOPSGetProvidingPowerSourceType string to a compact token.
    static func mapPowerSourceType(_ raw: String?) -> String? {
        switch raw {
        case kIOPSBatteryPowerValue: return "battery"
        case kIOPSACPowerValue: return "ac"
        case "UPS Power": return "ups"
        default: return raw == nil ? nil : "ac"
        }
    }

    /// Battery + charge estimates + providing-source + Low Power Mode. Battery stays
    /// `nil` on desktops (no fake 100%); powerSource is still reported ("ac").
    static func samplePower() -> PowerSample {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSample(battery: nil, powerSource: nil, lowPowerMode: lowPower)
        }
        let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        let powerSource = mapPowerSourceType(providing)

        var battery: BatterySample?
        if let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                guard let type = description[kIOPSTypeKey] as? String,
                      type == kIOPSInternalBatteryType else { continue }
                guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
                else { continue }
                let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
                battery = BatterySample(
                    level: clamp01(Double(current) / Double(max)),
                    charging: charging,
                    isCharged: description[kIOPSIsChargedKey] as? Bool,
                    minutesRemaining: mapIOPSMinutes(description[kIOPSTimeToEmptyKey] as? Int),
                    minutesToFull: mapIOPSMinutes(description[kIOPSTimeToFullChargeKey] as? Int)
                )
                break
            }
        }
        return PowerSample(battery: battery, powerSource: powerSource, lowPowerMode: lowPower)
    }

    /// Retained for callers that only need level + charging (backward-compatible).
    static func sampleBattery() -> BatterySample? {
        samplePower().battery
    }

    // MARK: - Thermal

    static func thermalString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    // MARK: - Load average

    static func sampleLoadAverage1() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) > 0 else { return nil }
        return loads[0]
    }

    // MARK: - Top processes (libproc)

    struct ProcessCPUCounters: Sendable {
        var totalTimeNanos: UInt64
    }

    struct TopProcessesResult: Sendable {
        var samples: [MonitorProcessSample]
        var counters: [Int32: ProcessCPUCounters]
    }

    /// Best-effort: enumerates PIDs via `proc_listallpids`, reads task CPU time +
    /// resident size via `proc_pidinfo(PROC_PIDTASKINFO)`, diffs CPU time against the
    /// previous counters, and returns the top `limit` by CPU-time delta. Any failure
    /// path yields fewer/no rows rather than crashing — this is behind a flag.
    static func sampleTopProcesses(
        previous: [Int32: ProcessCPUCounters],
        interval: TimeInterval,
        limit: Int
    ) -> TopProcessesResult {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return TopProcessesResult(samples: [], counters: [:]) }

        var pids = [Int32](repeating: 0, count: Int(capacity))
        let byteCount = proc_listallpids(&pids, capacity * Int32(MemoryLayout<Int32>.stride))
        guard byteCount > 0 else { return TopProcessesResult(samples: [], counters: [:]) }
        let pidCount = Int(byteCount) / MemoryLayout<Int32>.stride

        var counters: [Int32: ProcessCPUCounters] = [:]
        counters.reserveCapacity(pidCount)
        var scored: [(pid: Int32, cpu: Double, mem: UInt64)] = []
        let intervalNanos = max(interval, 0.001) * 1_000_000_000

        for index in 0..<min(pidCount, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
            guard read == size else { continue }

            let totalTime = info.pti_total_user &+ info.pti_total_system
            counters[pid] = ProcessCPUCounters(totalTimeNanos: totalTime)

            guard let prev = previous[pid] else { continue }
            let delta = totalTime &- prev.totalTimeNanos
            let cpuPercent = clamp01(Double(delta) / intervalNanos) * 100.0
            guard cpuPercent > 0 else { continue }
            scored.append((pid, cpuPercent, info.pti_resident_size))
        }

        let top = scored.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let samples = top.map { entry in
            MonitorProcessSample(
                name: processName(pid: entry.pid),
                cpuPercent: entry.cpu,
                memBytes: entry.mem
            )
        }
        return TopProcessesResult(samples: samples, counters: counters)
    }

    private static func processName(pid: Int32) -> String {
        // `PROC_PIDPATHINFO_MAXSIZE` isn't importable into Swift (macro marked
        // unavailable); a process name fits comfortably in MAXPATHLEN bytes.
        var buffer = [UInt8](repeating: 0, count: 1024)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            let name = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return "pid \(pid)"
    }

    // MARK: - Accessory batteries (IORegistry HID)

    /// Walks `AppleDeviceManagementHIDEventService` registry entries for a
    /// `BatteryPercent` property (Magic Mouse / Keyboard / Trackpad). Only real
    /// readings are returned — never fabricated. AirPods report through a different
    /// path and simply won't appear here (acceptable).
    static func sampleAccessoryBatteries() -> [MonitorAccessoryBattery] {
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var accessories: [MonitorAccessoryBattery] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }

            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(current, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let percent = (dict["BatteryPercent"] as? NSNumber)?.doubleValue {
                let product = (dict["Product"] as? String) ?? "Accessory"
                accessories.append(MonitorAccessoryBattery(
                    name: product,
                    kind: accessoryKind(productName: product),
                    percent: clamp01(percent / 100.0)
                ))
            }
            entry = IOIteratorNext(iterator)
        }
        return accessories
    }

    /// Heuristic device kind from the product name.
    static func accessoryKind(productName: String) -> String {
        let lower = productName.lowercased()
        if lower.contains("trackpad") { return "trackpad" }
        if lower.contains("mouse") { return "mouse" }
        if lower.contains("keyboard") { return "keyboard" }
        return "other"
    }

    // MARK: - Neural Engine footprint (proc_pid_rusage RUSAGE_INFO_V6)

    struct ANESample: Sendable {
        var processes: [MonitorANEProcess]
        var active: Bool
    }

    /// Enumerates PIDs and reads `ri_neural_footprint` via
    /// `proc_pid_rusage(RUSAGE_INFO_V6)` (public, no root, sandbox-safe). Keeps the top
    /// `limit` processes with footprint > 0; `active` is true if any footprint > 0.
    /// This walk is not free — call at a ≥5s cadence and only when demanded.
    static func sampleANE(limit: Int = 5) -> ANESample {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return ANESample(processes: [], active: false) }

        var pids = [Int32](repeating: 0, count: Int(capacity))
        let byteCount = proc_listallpids(&pids, capacity * Int32(MemoryLayout<Int32>.stride))
        guard byteCount > 0 else { return ANESample(processes: [], active: false) }
        let pidCount = Int(byteCount) / MemoryLayout<Int32>.stride

        var scored: [(pid: Int32, footprint: UInt64)] = []
        for index in 0..<min(pidCount, pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                ptr.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
                }
            }
            guard rc == 0, info.ri_neural_footprint > 0 else { continue }
            scored.append((pid, info.ri_neural_footprint))
        }

        let top = scored.sorted { $0.footprint > $1.footprint }.prefix(limit)
        let processes = top.map { entry in
            MonitorANEProcess(name: processName(pid: entry.pid), footprintBytes: entry.footprint)
        }
        return ANESample(processes: processes, active: !scored.isEmpty)
    }

    // MARK: - sysctl scalars

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    // MARK: - Helpers

    static func rate(current: UInt64, previous: UInt64, interval: TimeInterval) -> Double {
        guard interval > 0, current >= previous else { return 0 }
        return Double(current - previous) / interval
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
