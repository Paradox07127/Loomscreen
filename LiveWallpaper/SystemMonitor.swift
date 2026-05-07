import Foundation
import Observation
import Darwin
import IOKit

struct MonitoringReferenceCounter {
    private var count = 0

    mutating func start() -> Bool {
        count += 1
        return count == 1
    }

    mutating func stop() -> Bool {
        guard count > 0 else { return false }
        count -= 1
        return count == 0
    }
}

enum EstimatedFrameTickPolicy {
    private static let fallbackFPS = 30.0

    static func tickCount(forFrameRate frameRate: Double, interval: TimeInterval) -> Int {
        let effectiveFPS = frameRate > 0 ? frameRate : fallbackFPS
        return max(1, Int((effectiveFPS * interval).rounded()))
    }
}

enum MonitoringCadencePolicy {
    static func shouldSampleGPU(updateCount: Int, cadence: Int) -> Bool {
        guard cadence > 1, updateCount > 1 else { return true }
        return updateCount % cadence == 0
    }
}

enum MonitoringStartPolicy {
    static let initialSampleDelay: Duration = .milliseconds(350)
}

@MainActor @Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var cpuUsage: Double = 0
    private(set) var systemCpuUsage: Double = 0
    private(set) var memoryUsage: UInt64 = 0
    private(set) var totalMemory: UInt64 = 0
    private(set) var isMemoryLow: Bool = false
    private(set) var systemMemoryUsage: Double = 0
    private(set) var gpuUsage: Double = 0
    private(set) var energyImpact: Double = 0
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var videoFPS: Double = 0

    // MARK: - Configuration

    @ObservationIgnored private let memoryWarningThreshold: Double = 0.85
    @ObservationIgnored private var updateInterval: TimeInterval = 2.0
    @ObservationIgnored private let gpuSampleCadence = 3
    @ObservationIgnored private var resourceUpdateCount = 0
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var fpsCounter = FPSCounter()
    @ObservationIgnored private var references = MonitoringReferenceCounter()
    @ObservationIgnored private var prevHostCpuLoad: host_cpu_load_info?

    private init() {
        totalMemory = ProcessInfo.processInfo.physicalMemory
    }

    // MARK: - Public Methods

    func startMonitoring() {
        guard references.start() else { return }
        let interval = updateInterval
        let initialSampleDelay = MonitoringStartPolicy.initialSampleDelay
        resourceUpdateCount = 0
        updateTask = Task {
            do {
                try await Task.sleep(for: initialSampleDelay)
            } catch {
                return
            }
            self.updateResourceUsage()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                self.updateResourceUsage()
            }
        }
    }

    func stopMonitoring() {
        guard references.stop() else { return }
        updateTask?.cancel()
        updateTask = nil
    }

    /// Call this from real render loops to track actual FPS.
    func tickFrame() {
        fpsCounter.tick()
    }

    /// AVPlayer does not expose rendered-frame callbacks here; record an estimate.
    func tickEstimatedFrames(_ count: Int) {
        fpsCounter.tick(count: count)
    }

    func formattedMemoryUsage() -> String { FormatUtils.formatBytes(memoryUsage) }
    func formattedTotalMemory() -> String { FormatUtils.formatBytes(totalMemory) }
    func memoryPercentage() -> Double {
        guard totalMemory > 0 else { return 0 }
        return Double(memoryUsage) / Double(totalMemory) * 100.0
    }

    var thermalStateDescription: String {
        switch thermalState {
        case .nominal:  return "Normal"
        case .fair:     return "Elevated"
        case .serious:  return "High"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    // MARK: - Update Loop

    private func updateResourceUsage() {
        resourceUpdateCount += 1
        cpuUsage = getAppCPUUsage()
        systemCpuUsage = getSystemCPUUsage()
        memoryUsage = getAppMemoryUsage()
        systemMemoryUsage = getSystemMemoryUsage()
        if MonitoringCadencePolicy.shouldSampleGPU(updateCount: resourceUpdateCount, cadence: gpuSampleCadence) {
            gpuUsage = getGPUUsage()
        }
        energyImpact = getEnergyImpact()
        thermalState = ProcessInfo.processInfo.thermalState
        videoFPS = fpsCounter.fps
        checkMemoryWarning()
    }

    private func checkMemoryWarning() {
        let isLow = systemMemoryUsage > memoryWarningThreshold
        if isLow != isMemoryLow {
            isMemoryLow = isLow
            if isLow {
                Logger.warning("System memory usage is high: \(Int(systemMemoryUsage * 100))%", category: .memory)
                NotificationCenter.default.post(
                    name: .systemMemoryWarning,
                    object: nil,
                    userInfo: ["memoryUsage": systemMemoryUsage]
                )
            }
        }
    }

    // MARK: - CPU Usage

    private func getAppCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)

        let result = task_threads(mach_task_self_, &threadsList, &threadsCount)

        if result == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

                let threadInfoResult = withUnsafeMutablePointer(to: &threadInfo) { ptr in
                    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { intPtr in
                        thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &threadInfoCount)
                    }
                }

                if threadInfoResult == KERN_SUCCESS {
                    if threadInfo.flags & TH_FLAGS_IDLE == 0 {
                        totalUsageOfCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)
                    }
                }
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)),
                          vm_size_t(Int(threadsCount) * MemoryLayout<thread_act_t>.stride))
        }

        let coreCount = Double(ProcessInfo.processInfo.activeProcessorCount)
        return min(totalUsageOfCPU / coreCount * 100, 100.0)
    }

    // MARK: - System-wide CPU Usage

    private func getSystemCPUUsage() -> Double {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return systemCpuUsage }

        defer { prevHostCpuLoad = info }
        guard let prev = prevHostCpuLoad else { return 0 }

        let userDelta   = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let systemDelta = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idleDelta   = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let niceDelta   = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let busy = userDelta + systemDelta + niceDelta
        let total = busy + idleDelta
        guard total > 0 else { return systemCpuUsage }
        return min(100, max(0, busy / total * 100))
    }

    // MARK: - Memory Usage

    private func getAppMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func getSystemMemoryUsage() -> Double {
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64_data_t()

        host_page_size(hostPort, &pageSize)

        let status = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &hostSize)
            }
        }

        guard status == KERN_SUCCESS else { return 0.0 }

        let used = Double(vmStats.active_count + vmStats.wire_count + vmStats.compressor_page_count) * Double(pageSize)
        return used / Double(ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - GPU Usage (via IOKit)

    private func getGPUUsage() -> Double {
        var iterator: io_iterator_t = 0
        let matchDict = IOServiceMatching("IOAccelerator")

        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var gpuUtil: Double = 0
        var entry: io_registry_entry_t = IOIteratorNext(iterator)

        while entry != 0 {
            defer { IOObjectRelease(entry) }

            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any] {

                if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                    if let util = perfStats["GPU Activity(%)"] as? Double {
                        gpuUtil = util
                    } else if let util = perfStats["Device Utilization %"] as? Int {
                        gpuUtil = Double(util)
                    } else if let util = perfStats["gpuCoreUtilizationComponent"] as? Int {
                        gpuUtil = Double(util)
                    }
                }
            }

            entry = IOIteratorNext(iterator)
        }

        return min(gpuUtil, 100.0)
    }

    // MARK: - Energy Impact (via task_info)

    private func getEnergyImpact() -> Double {
        var power = task_power_info_v2_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &power) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let nanojoules = Double(power.gpu_energy.task_gpu_utilisation)
        let watts = nanojoules / (updateInterval * 1_000_000_000)
        return watts
    }
}

// MARK: - FPS Counter

private class FPSCounter {
    private var timestamps: [CFAbsoluteTime] = []
    private let window: TimeInterval = 2.0

    var fps: Double {
        let now = CFAbsoluteTimeGetCurrent()
        timestamps.removeAll { now - $0 > window }
        guard timestamps.count > 1, let first = timestamps.first else { return 0 }
        return Double(timestamps.count - 1) / (now - first)
    }

    func tick() {
        tick(count: 1)
    }

    func tick(count: Int) {
        guard count > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        timestamps.append(contentsOf: repeatElement(now, count: count))
        if timestamps.count > 300 {
            timestamps.removeFirst(timestamps.count - 200)
        }
    }
}
