import Foundation
import Combine
import Darwin

class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsage: UInt64 = 0
    @Published private(set) var totalMemory: UInt64 = 0
    @Published private(set) var isMemoryLow: Bool = false
    @Published private(set) var systemMemoryUsage: Double = 0
    
    private let memoryWarningThreshold: Double = 0.85 // 85% memory usage
    private var updateInterval: TimeInterval = 2.0 // Update every 2 seconds
    private var updateTimer: Timer?
    
    private init() {
        totalMemory = ProcessInfo.processInfo.physicalMemory
        Logger.debug("System monitor initialized. Total memory: \(formatBytes(totalMemory))", category: .memory)
    }
    
    // MARK: - Public Methods
    
    // Start monitoring system resources
    func startMonitoring() {
        stopMonitoring()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateResourceUsage()
        }
        
        // Force immediate update
        updateResourceUsage()
    }
    
    // Stop monitoring system resources
    func stopMonitoring() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    // MARK: - Formatted Output Methods
    
    // Get formatted memory usage - for compatibility with original code
    func formattedMemoryUsage() -> String {
        return formatBytes(memoryUsage)
    }
    
    // Get formatted total memory
    func formattedTotalMemory() -> String {
        return formatBytes(totalMemory)
    }
    
    // Get memory usage as percentage - for compatibility with original code
    func memoryPercentage() -> Double {
        guard totalMemory > 0 else { return 0 }
        return Double(memoryUsage) / Double(totalMemory) * 100.0
    }
    
    // MARK: - Private Implementation
    
    private func updateResourceUsage() {
        cpuUsage = getAppCPUUsage()
        memoryUsage = getAppMemoryUsage()
        systemMemoryUsage = getSystemMemoryUsage()
        checkMemoryWarning()
    }
    
    private func checkMemoryWarning() {
        let isLow = systemMemoryUsage > memoryWarningThreshold
        
        if isLow != isMemoryLow {
            isMemoryLow = isLow
            if isLow {
                Logger.warning("System memory usage is high: \(Int(systemMemoryUsage * 100))%", category: .memory)
                // Post notification for low memory warning
                NotificationCenter.default.post(
                    name: Notification.Name("SystemMemoryWarning"),
                    object: nil,
                    userInfo: ["memoryUsage": systemMemoryUsage]
                )
            }
        }
    }
    
    // MARK: - Resource Monitoring Implementation
    
    private func getAppMemoryUsage() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return info.phys_footprint
        }
        
        return 0
    }
    
    private func getSystemMemoryUsage() -> Double {
        var pageSize: vm_size_t = 0
        let hostPort = mach_host_self()
        var host_size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64_data_t()
        
        host_page_size(hostPort, &pageSize)
        
        let status = withUnsafeMutablePointer(to: &vmStats) { vmStatsPointer in
            vmStatsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(host_size)) { pointer in
                host_statistics64(hostPort, HOST_VM_INFO64, pointer, &host_size)
            }
        }
        
        guard status == KERN_SUCCESS else {
            Logger.error("Failed to get memory statistics", category: .memory)
            return 0.0
        }
        
        let active = Double(vmStats.active_count) * Double(pageSize)
        let wired = Double(vmStats.wire_count) * Double(pageSize)
        let compressed = Double(vmStats.compressor_page_count) * Double(pageSize)
        
        let used = active + wired + compressed
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        
        return used / total
    }
    
    private func getAppCPUUsage() -> Double {
        var totalUsageOfCPU: Double = 0.0
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        
        let result = task_threads(mach_task_self_, &threadsList, &threadsCount)
        
        if result == KERN_SUCCESS, let threadsList = threadsList {
            for index in 0..<threadsCount {
                var threadInfo = thread_basic_info()
                var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
                
                let threadInfoResult = withUnsafeMutablePointer(to: &threadInfo) { threadInfoPtr in
                    threadInfoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) { threadInfoIntPtr in
                        thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), threadInfoIntPtr, &threadInfoCount)
                    }
                }
                
                if threadInfoResult == KERN_SUCCESS {
                    let threadBasicInfo = threadInfo
                    if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                        totalUsageOfCPU = (totalUsageOfCPU + (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE)))
                    }
                }
            }
            
            // Free the memory associated with the thread list
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_act_t>.stride))
        }
        
        return min(totalUsageOfCPU * 100, 100.0) // Return as percentage, capped at 100%
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.1f MB", mb)
        } else {
            return String(format: "%.0f KB", kb)
        }
    }
}
