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
        updateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: initialSampleDelay)
            } catch {
                return
            }
            await self?.sampleAndApply()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
                await self?.sampleAndApply()
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
        case .nominal:
            return String(localized: "Normal", defaultValue: "Normal", comment: "Thermal state label.")
        case .fair:
            return String(localized: "Elevated", defaultValue: "Elevated", comment: "Thermal state label.")
        case .serious:
            return String(localized: "High", defaultValue: "High", comment: "Thermal state label.")
        case .critical:
            return String(localized: "Critical", defaultValue: "Critical", comment: "Thermal state label.")
        @unknown default:
            return String(localized: "Unknown", defaultValue: "Unknown", comment: "Thermal state label.")
        }
    }

    // MARK: - Update Loop

    /// Captures a full system snapshot off-MainActor and reapplies the
    /// derived values back on MainActor with diff guards. The sampling code
    /// itself only touches Mach/IOKit/VM-stat APIs that have no main-thread
    /// requirement, so moving them off the main queue eliminates the
    /// recurring 2-second main-thread spike from the previous design.
    private func sampleAndApply() async {
        resourceUpdateCount += 1
        let updateCount = resourceUpdateCount
        let interval = updateInterval
        let prev = HostCpuLoadSnapshot(value: prevHostCpuLoad)
        let shouldSampleGPU = MonitoringCadencePolicy.shouldSampleGPU(
            updateCount: updateCount,
            cadence: gpuSampleCadence
        )

        let sample = await Task.detached(priority: .utility) { () -> SystemSample in
            let cpuResult = SystemMonitor.sampleSystemCPUUsage(prev: prev.value)
            return SystemSample(
                cpuUsage: SystemMonitor.sampleAppCPUUsage(),
                systemCpuUsage: cpuResult.usage,
                newHostCpuLoad: HostCpuLoadSnapshot(value: cpuResult.newPrev),
                memoryUsage: SystemMonitor.sampleAppMemoryUsage(),
                systemMemoryUsage: SystemMonitor.sampleSystemMemoryUsage(),
                gpuUsage: shouldSampleGPU ? SystemMonitor.sampleGPUUsage() : nil,
                energyImpact: SystemMonitor.sampleEnergyImpact(updateInterval: interval),
                thermalState: ProcessInfo.processInfo.thermalState
            )
        }.value

        // `Task.detached` runs outside the monitor task's cancellation
        // scope, so a sample that was already in flight when
        // `stopMonitoring()` ran would otherwise still write back. Re-check
        // here to keep one-shot late samples from reviving the published
        // properties after the dashboard left the screen.
        guard !Task.isCancelled else { return }
        applySample(sample)
    }

    /// Reapplies a sample on MainActor with diff guards so views observing
    /// individual properties (cpuUsage, gpuUsage, …) re-evaluate only when
    /// the value materially changed. Per-property epsilons suppress the
    /// constant micro-fluctuation that otherwise drove a re-render every
    /// 2 seconds even when the dashboard was visually identical.
    private func applySample(_ sample: SystemSample) {
        if abs(cpuUsage - sample.cpuUsage) > Self.percentMaterialEpsilon {
            cpuUsage = sample.cpuUsage
        }
        if let systemCpu = sample.systemCpuUsage,
           abs(systemCpuUsage - systemCpu) > Self.percentMaterialEpsilon {
            systemCpuUsage = systemCpu
        }
        prevHostCpuLoad = sample.newHostCpuLoad.value
        if memoryUsage != sample.memoryUsage {
            memoryUsage = sample.memoryUsage
        }
        if abs(systemMemoryUsage - sample.systemMemoryUsage) > Self.ratioMaterialEpsilon {
            systemMemoryUsage = sample.systemMemoryUsage
        }
        if let gpu = sample.gpuUsage,
           abs(gpuUsage - gpu) > Self.percentMaterialEpsilon {
            gpuUsage = gpu
        }
        if abs(energyImpact - sample.energyImpact) > Self.energyMaterialEpsilon {
            energyImpact = sample.energyImpact
        }
        if thermalState != sample.thermalState {
            thermalState = sample.thermalState
        }
        let fps = fpsCounter.fps
        if abs(videoFPS - fps) > Self.fpsMaterialEpsilon {
            videoFPS = fps
        }
        checkMemoryWarning()
    }

    // Material-change thresholds tuned for human perception, not raw
    // precision — at a 2-second refresh rate, sub-percent CPU/GPU swings
    // and sub-percent RAM jitter aren't readable, so writing them only
    // churns the SwiftUI render loop without giving the user new info.
    @ObservationIgnored private static let percentMaterialEpsilon: Double = 1.0
    @ObservationIgnored private static let ratioMaterialEpsilon: Double = 0.01
    @ObservationIgnored private static let energyMaterialEpsilon: Double = 0.1
    @ObservationIgnored private static let fpsMaterialEpsilon: Double = 0.5

    private struct HostCpuLoadSnapshot: @unchecked Sendable {
        let value: host_cpu_load_info?
    }

    private struct SystemSample: @unchecked Sendable {
        let cpuUsage: Double
        let systemCpuUsage: Double?
        let newHostCpuLoad: HostCpuLoadSnapshot
        let memoryUsage: UInt64
        let systemMemoryUsage: Double
        let gpuUsage: Double?
        let energyImpact: Double
        let thermalState: ProcessInfo.ThermalState
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

    nonisolated private static func sampleAppCPUUsage() -> Double {
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

    /// Returns `(usage, newPrev)`. `usage` is `nil` when the host-statistics
    /// call fails or returns a degenerate tick delta — callers keep the
    /// previously observed value in that case. `newPrev` is the latest
    /// `host_cpu_load_info` snapshot which the caller stores back on
    /// MainActor for the next iteration's delta computation.
    nonisolated private static func sampleSystemCPUUsage(
        prev: host_cpu_load_info?
    ) -> (usage: Double?, newPrev: host_cpu_load_info?) {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { intPtr in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, intPtr, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, prev) }

        let newPrev: host_cpu_load_info? = info
        guard let prev else { return (0, newPrev) }

        let userDelta   = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let systemDelta = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idleDelta   = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let niceDelta   = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let busy = userDelta + systemDelta + niceDelta
        let total = busy + idleDelta
        guard total > 0 else { return (nil, newPrev) }
        return (min(100, max(0, busy / total * 100)), newPrev)
    }

    // MARK: - Memory Usage

    nonisolated private static func sampleAppMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    nonisolated private static func sampleSystemMemoryUsage() -> Double {
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

    nonisolated private static func sampleGPUUsage() -> Double {
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

    nonisolated private static func sampleEnergyImpact(updateInterval: TimeInterval) -> Double {
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
