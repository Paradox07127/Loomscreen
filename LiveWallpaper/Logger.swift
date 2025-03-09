import Foundation
import os.log

// A centralized logging system for the LiveWallpaper application
// Provides structured, categorized logging with appropriate verbosity controls
final class Logger {
    // MARK: - Log Categories
    
    // Log categories to organize logs by subsystem
    enum Category: String, CaseIterable {
        case general = "General"
        case screenManager = "ScreenManager"
        case videoPlayer = "VideoPlayer"
        case powerMonitor = "PowerMonitor"
        case fileAccess = "FileAccess"
        case settings = "Settings"
        case ui = "UserInterface"
        case performance = "Performance"
        case startup = "Startup"
        case lifecycle = "Lifecycle"
        case memory = "Memory"
        
        // Returns the OSLog object for this category
        var log: OSLog {
            OSLog(subsystem: "com.livewallpaper", category: self.rawValue)
        }
    }
    
    // MARK: - Log Levels
    
    // Log level to control verbosity and visibility
    enum Level {
        case debug    // Development-only logging
        case info     // General information
        case notice   // Important events
        case warning  // Potential issues
        case error    // Errors that need attention
        case fault    // Critical errors
        
        // Maps Level to OSLogType
        var osLogType: OSLogType {
            switch self {
            case .debug:    return .debug
            case .info:     return .info
            case .notice:   return .default
            case .warning:  return .default
            case .error:    return .error
            case .fault:    return .fault
            }
        }
        
        // Emoji prefix for better visual identification
        var prefix: String {
            switch self {
            case .debug:    return "🔍"
            case .info:     return "ℹ️"
            case .notice:   return "📢"
            case .warning:  return "⚠️"
            case .error:    return "❌"
            case .fault:    return "🔥"
            }
        }
    }
    
    // MARK: - Configuration
    
    // Determines if debug logs are shown even in release builds (default false)
    static var showDebugInRelease: Bool = false
    
    // Enable/disable log categories at runtime
    static var enabledCategories: Set<Category> = Set(Category.allCases)
    
    // MARK: - Logging Methods
    
    // Log a message with the specified category and level
    // - Parameters:
    //   - message: The message to log
    //   - category: The log category
    //   - level: The log level
    //   - file: The file where the log was called from
    //   - function: The function where the log was called from
    //   - line: The line where the log was called from
    static func log(
        _ message: String,
        category: Category,
        level: Level = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        // Skip logging if the category is disabled
        guard enabledCategories.contains(category) else { return }
        
        // Skip debug logs in release builds unless explicitly enabled
        #if !DEBUG
        if level == .debug && !showDebugInRelease { return }
        #endif
        
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logMessage = "\(level.prefix) [\(fileName):\(line)] \(function) - \(message)"
        
        os_log("%{public}@", log: category.log, type: level.osLogType, logMessage)
    }
    
    // MARK: - Convenience Methods
    
    // Log a debug message (only in DEBUG builds by default)
    static func debug(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #else
        if showDebugInRelease {
            log(message, category: category, level: .debug, file: file, function: function, line: line)
        }
        #endif
    }
    
    // Log an info message
    static func info(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .info, file: file, function: function, line: line)
    }
    
    // Log a notice message
    static func notice(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .notice, file: file, function: function, line: line)
    }
    
    // Log a warning message
    static func warning(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .warning, file: file, function: function, line: line)
    }
    
    // Log an error message
    static func error(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .error, file: file, function: function, line: line)
    }
    
    // Log a fault message for critical errors
    static func fault(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .fault, file: file, function: function, line: line)
    }
    
    // MARK: - Function Lifecycle Logging
    
    // Log the start of a function
    static func functionStart(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Started", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    // Log the end of a function
    static func functionEnd(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Finished", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    // MARK: - Special Purpose Logging
    
    // Log a value with message
    static func value<T>(_ value: T, message: String? = nil, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let message = message != nil ? "\(message!): \(value)" : "Value: \(value)"
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    // Log time elapsed from a start time
    static func timeElapsed(from startTime: CFAbsoluteTime, description: String? = nil, category: Category = .performance, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let message = description != nil ? "\(description!) - Time: \(String(format: "%.4f", elapsed))s" : "Time elapsed: \(String(format: "%.4f", elapsed))s"
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    // MARK: - Resource Monitoring Logs
    
    // Log memory usage
    static func memoryUsage(bytes: UInt64, category: Category = .memory, file: String = #file, function: String = #function, line: Int = #line) {
        let formattedSize = formatByteSize(bytes)
        log("Memory usage: \(formattedSize)", category: category, level: .debug, file: file, function: function, line: line)
    }
    
    // Log CPU usage
    static func cpuUsage(_ percentage: Double, category: Category = .performance, file: String = #file, function: String = #function, line: Int = #line) {
        log("CPU usage: \(String(format: "%.1f", percentage))%", category: category, level: .debug, file: file, function: function, line: line)
    }
    
    // MARK: - Video Player Specific Logs
    
    // Log video loading
    static func videoLoaded(url: URL, screenID: UInt32, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = url.lastPathComponent
        log("Video loaded: \(fileName) for screen \(screenID)", category: .videoPlayer, level: .info, file: file, function: function, line: line)
    }
    
    // Log playback state change
    static func playbackStateChanged(isPlaying: Bool, screenID: UInt32, file: String = #file, function: String = #function, line: Int = #line) {
        let state = isPlaying ? "playing" : "paused"
        log("Playback \(state) on screen \(screenID)", category: .videoPlayer, level: .info, file: file, function: function, line: line)
    }
    
    // Log video error
    static func videoError(_ error: Error, screenID: UInt32, file: String = #file, function: String = #function, line: Int = #line) {
        log("Video error on screen \(screenID): \(error.localizedDescription)", category: .videoPlayer, level: .error, file: file, function: function, line: line)
    }
    
    // MARK: - Screen Management Logs
    
    // Log screen detection
    static func screensDetected(_ count: Int, file: String = #file, function: String = #function, line: Int = #line) {
        log("Detected \(count) screens", category: .screenManager, level: .notice, file: file, function: function, line: line)
    }
    
    // Log screen configuration
    static func screenConfigured(id: UInt32, resolution: String, file: String = #file, function: String = #function, line: Int = #line) {
        log("Configured screen \(id) (\(resolution))", category: .screenManager, level: .info, file: file, function: function, line: line)
    }
    
    // MARK: - Power Management Logs
    
    // Log power source change
    static func powerSourceChanged(isOnBattery: Bool, level: Double?, file: String = #file, function: String = #function, line: Int = #line) {
        let source = isOnBattery ? "battery" : "AC power"
        var message = "Power source changed to \(source)"
        if let level = level, isOnBattery {
            message += " (level: \(Int(level * 100))%)"
        }
        log(message, category: .powerMonitor, level: .notice, file: file, function: function, line: line)
    }
    
    // MARK: - Settings Logs
    
    // Log settings change
    static func settingsChanged(setting: String, value: Any, file: String = #file, function: String = #function, line: Int = #line) {
        log("Setting changed: \(setting) = \(value)", category: .settings, level: .info, file: file, function: function, line: line)
    }
    
    // MARK: - Helper Methods
    
    // Format byte size to human-readable string
    private static func formatByteSize(_ bytes: UInt64) -> String {
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

// MARK: - Performance Measuring

// Utility class for measuring performance of code blocks
class PerformanceTimer {
    private let startTime: CFAbsoluteTime
    private let description: String
    private let category: Logger.Category
    private let file: String
    private let function: String
    private let line: Int
    private var checkpoints: [String: CFAbsoluteTime] = [:]
    
    init(description: String, category: Logger.Category = .performance, file: String = #file, function: String = #function, line: Int = #line) {
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.description = description
        self.category = category
        self.file = file
        self.function = function
        self.line = line
        
        Logger.debug("⏱ \(description) - Started", category: category, file: file, function: function, line: line)
    }
    
    // Record a checkpoint with a label
    func checkpoint(_ label: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - startTime
        checkpoints[label] = now
        
        Logger.debug("⏱ \(description) - Checkpoint '\(label)' at \(String(format: "%.4f", elapsed))s",
                   category: category, file: file, function: function, line: line)
    }
    
    // Measure time between two checkpoints
    func timeBetween(from: String, to: String) -> TimeInterval? {
        guard let fromTime = checkpoints[from], let toTime = checkpoints[to] else {
            return nil
        }
        return toTime - fromTime
    }
    
    deinit {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        Logger.debug("⏱ \(description) - Finished in \(String(format: "%.4f", elapsed))s",
                   category: category, file: file, function: function, line: line)
    }
}

// MARK: - File Operation Logging Helper

// Helper for logging file operations
struct FileLogger {
    // Log file read operation
    static func read(path: String, success: Bool, category: Logger.Category = .fileAccess, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let result = success ? "succeeded" : "failed"
        Logger.debug("Read file \(fileName) \(result)", category: category, file: file, function: function, line: line)
    }
    
    // Log file write operation
    static func write(path: String, success: Bool, category: Logger.Category = .fileAccess, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let result = success ? "succeeded" : "failed"
        Logger.debug("Write to file \(fileName) \(result)", category: category, file: file, function: function, line: line)
    }
    
    // Log file security access
    static func securityScopedAccess(path: String, granted: Bool, category: Logger.Category = .fileAccess, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let result = granted ? "granted" : "denied"
        Logger.info("Security-scoped access \(result) for \(fileName)", category: category, file: file, function: function, line: line)
    }
}
