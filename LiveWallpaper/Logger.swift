import Foundation
import os.log

/// A centralized logging system for the LiveWallpaper application
final class Logger {
    // MARK: - Log Categories
    
    /// Log categories to organize logs by subsystem
    enum Category: String {
        case general = "General"
        case screenManager = "ScreenManager"
        case videoPlayer = "VideoPlayer"
        case powerMonitor = "PowerMonitor"
        case fileAccess = "FileAccess"
        case settings = "Settings"
        case ui = "UserInterface"
        
        /// Returns the OSLog object for this category
        var log: OSLog {
            OSLog(subsystem: "com.livewallpaper", category: self.rawValue)
        }
    }
    
    // MARK: - Log Levels
    
    /// Log level to control verbosity and visibility
    enum Level {
        case debug    // Development-only logging
        case info     // General information
        case notice   // Important events
        case warning  // Potential issues
        case error    // Errors that need attention
        case fault    // Critical errors
        
        /// Maps Level to OSLogType
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
        
        /// Emoji prefix for better visual identification
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
    
    // MARK: - Logging Methods
    
    /// Log a message with the specified category and level
    /// - Parameters:
    ///   - message: The message to log
    ///   - category: The log category
    ///   - level: The log level
    ///   - file: The file where the log was called from
    ///   - function: The function where the log was called from
    ///   - line: The line where the log was called from
    static func log(
        _ message: String,
        category: Category,
        level: Level = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logMessage = "\(level.prefix) [\(fileName):\(line)] \(function) - \(message)"
        
        os_log("%{public}@", log: category.log, type: level.osLogType, logMessage)
    }
    
    // MARK: - Convenience Methods
    
    /// Log a debug message
    static func debug(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    /// Log an info message
    static func info(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .info, file: file, function: function, line: line)
    }
    
    /// Log a notice message
    static func notice(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .notice, file: file, function: function, line: line)
    }
    
    /// Log a warning message
    static func warning(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .warning, file: file, function: function, line: line)
    }
    
    /// Log an error message
    static func error(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .error, file: file, function: function, line: line)
    }
    
    /// Log a fault message
    static func fault(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .fault, file: file, function: function, line: line)
    }
    
    // MARK: - Special Purpose Logging
    
    /// Log the start of a function
    static func functionStart(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Started", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    /// Log the end of a function
    static func functionEnd(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Finished", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    /// Log a value with message
    static func value<T>(_ value: T, message: String? = nil, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let message = message != nil ? "\(message!) \(value)" : "Value: \(value)"
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
    
    /// Log time elapsed from a start time
    static func timeElapsed(from startTime: CFAbsoluteTime, description: String? = nil, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let message = description != nil ? "\(description!) - Time: \(elapsed)s" : "Time elapsed: \(elapsed)s"
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }
}

// MARK: - Performance Measuring

/// Utility class for measuring performance
class PerformanceTimer {
    private let startTime: CFAbsoluteTime
    private let description: String
    private let category: Logger.Category
    private let file: String
    private let function: String
    private let line: Int
    
    init(description: String, category: Logger.Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.description = description
        self.category = category
        self.file = file
        self.function = function
        self.line = line
        
        Logger.debug("⏱ \(description) - Started", category: category, file: file, function: function, line: line)
    }
    
    deinit {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        Logger.debug("⏱ \(description) - Finished in \(String(format: "%.4f", elapsed))s", category: category, file: file, function: function, line: line)
    }
}
