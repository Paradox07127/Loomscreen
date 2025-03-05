import Foundation
import Combine

// Import necessary system frameworks
import Darwin

/// Monitors system and application resource usage
class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var memoryUsage: UInt64 = 0
    @Published private(set) var totalMemory: UInt64 = 0
    
    private var updateTimer: Timer?
    private var updateInterval: TimeInterval = 2.0 // Update every 2 seconds
    
    private init() {
        // Get total physical memory once
        totalMemory = getTotalMemory()
        startMonitoring()
    }
    
    func startMonitoring() {
        // Stop any existing timer
        stopMonitoring()
        
        // Create a new timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateResourceUsage()
        }
        
        // Force an immediate update
        updateResourceUsage()
    }
    
    func stopMonitoring() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func updateResourceUsage() {
        cpuUsage = getAppCPUUsage()
        memoryUsage = getAppMemoryUsage()
    }
    
    // MARK: - Memory Usage Monitoring
    
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
    
    private func getTotalMemory() -> UInt64 {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return physicalMemory
    }
    
    // MARK: - CPU Usage Monitoring
    
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
    
    // MARK: - Helper Methods
    
    func formattedMemoryUsage() -> String {
        return formatBytes(memoryUsage)
    }
    
    func formattedTotalMemory() -> String {
        return formatBytes(totalMemory)
    }
    
    func memoryPercentage() -> Double {
        guard totalMemory > 0 else { return 0 }
        return Double(memoryUsage) / Double(totalMemory) * 100.0
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
