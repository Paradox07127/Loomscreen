import Foundation
import Darwin
import IOKit
import IOKit.ps

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

        let result = host_processor_info(
            mach_host_self(),
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

    // MARK: - Memory

    struct MemorySample: Sendable {
        var usedBytes: UInt64
        var totalBytes: UInt64
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
            return MemorySample(usedBytes: 0, totalBytes: total)
        }
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return MemorySample(usedBytes: usedPages &* UInt64(pageSize), totalBytes: total)
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

    /// Mirrors `SystemMonitor.sampleGPUUsage`: reads `PerformanceStatistics` off the
    /// IOAccelerator registry entries, preferring the modern "Device Utilization %".
    static func sampleGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var found = false
        var gpuUtil: Double = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let current = entry
            defer { IOObjectRelease(current) }

            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(current, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                if let util = perfStats["Device Utilization %"] as? Int {
                    gpuUtil = Double(util); found = true
                } else if let util = perfStats["GPU Activity(%)"] as? Double {
                    gpuUtil = util; found = true
                } else if let util = perfStats["gpuCoreUtilizationComponent"] as? Int {
                    gpuUtil = Double(util); found = true
                }
            }
            entry = IOIteratorNext(iterator)
        }
        guard found else { return nil }
        return clamp01(gpuUtil / 100.0)
    }

    // MARK: - Network (getifaddrs, AF_LINK)

    /// Summed rx/tx byte counters across non-loopback, up interfaces. Paired with the
    /// previous read to yield bytes/sec; a negative delta (interface reset / counter
    /// wrap) is treated as 0.
    static func sampleNetworkCounters() -> (rx: UInt64, tx: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            defer { cursor = ifa.ifa_next }

            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let dataPtr = ifa.ifa_data else { continue }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            rx &+= UInt64(data.ifi_ibytes)
            tx &+= UInt64(data.ifi_obytes)
        }
        return (rx, tx)
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
    }

    /// `nil` on machines with no battery (desktops), so the snapshot leaves the
    /// battery fields absent rather than reporting a fake 100%.
    static func sampleBattery() -> BatterySample? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            return BatterySample(level: clamp01(Double(current) / Double(max)), charging: charging)
        }
        return nil
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
