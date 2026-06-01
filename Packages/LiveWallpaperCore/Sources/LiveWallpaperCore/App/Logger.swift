import Foundation
import os

public final class Logger {
    // MARK: - Log Categories

    public enum Category: String, CaseIterable, Sendable {
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
        case wpeResolver = "WPEResolver"
        case wpeRender = "WPERender"
        case audioCapture = "AudioCapture"

        public static let subsystem = "com.livewallpaper"

        /// Backing `os.Logger` for this category, lazily created and cached.
        /// `os.Logger` is a thin wrapper but caching avoids the per-call
        /// subsystem string interning.
        fileprivate var logger: os.Logger {
            LoggerCache.shared.logger(for: self)
        }
    }

    // MARK: - Log Levels

    public enum Level: Sendable {
        case debug, info, notice, warning, error, fault

        public var prefix: String {
            switch self {
            case .debug:    return "🔍"
            case .info:     return "ℹ️"
            case .notice:   return "📢"
            case .warning:  return "⚠️"
            case .error:    return "❌"
            case .fault:    return "🔥"
            }
        }

        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug:    return .debug
            case .info:     return .info
            case .notice:   return .default
            case .warning:  return .default
            case .error:    return .error
            case .fault:    return .fault
            }
        }
    }

    // MARK: - Core Logging

    /// `@autoclosure` defers string interpolation; the message is only evaluated when this level is actually being logged.

    public static func log(
        _ message: @autoclosure () -> String,
        category: Category,
        level: Level = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        #if !DEBUG
        if level == .debug { return }
        #endif

        let fileName = (file as NSString).lastPathComponent
        let body = message()
        category.logger.log(
            level: level.osLogType,
            "\(level.prefix, privacy: .public) [\(fileName, privacy: .public):\(line, privacy: .public)] \(function, privacy: .public) - \(body, privacy: .public)"
        )
        LogFileSink.shared.record(
            category: category,
            level: level,
            message: body,
            file: file,
            line: line
        )
    }

    /// Persistent log file path users can `tail -f`. `nil` only if the
    /// `~/Library/Logs/LiveWallpaper/` directory could not be created.
    public static var persistentLogFileURL: URL? {
        LogFileSink.shared.fileURL
    }

    // MARK: - Convenience Methods

    public static func debug(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(message(), category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .info, file: file, function: function, line: line)
    }

    public static func notice(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .notice, file: file, function: function, line: line)
    }

    public static func warning(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .warning, file: file, function: function, line: line)
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .error, file: file, function: function, line: line)
    }

    public static func fault(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message(), category: category, level: .fault, file: file, function: function, line: line)
    }

    // MARK: - Lifecycle Logging

    public static func functionStart(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Started", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    public static func functionEnd(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Finished", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    // MARK: - Domain-Specific Logging

    public static func screensDetected(_ count: Int, file: String = #file, function: String = #function, line: Int = #line) {
        log("Detected \(count) screens", category: .screenManager, level: .notice, file: file, function: function, line: line)
    }

    public static func powerSourceChanged(isOnBattery: Bool, level: Double?, file: String = #file, function: String = #function, line: Int = #line) {
        let source = isOnBattery ? "battery" : "AC power"
        var message = "Power source changed to \(source)"
        if let level = level, isOnBattery {
            message += " (level: \(Int(level * 100))%)"
        }
        log(message, category: .powerMonitor, level: .notice, file: file, function: function, line: line)
    }

    public static func settingsChanged(setting: String, value: Any, file: String = #file, function: String = #function, line: Int = #line) {
        log("Setting changed: \(setting) = \(value)", category: .settings, level: .info, file: file, function: function, line: line)
    }
}

// MARK: - Performance Measuring

public class PerformanceTimer {
    private let startTime: CFAbsoluteTime
    private let description: String
    private let category: Logger.Category
    private let file: String
    private let function: String
    private let line: Int

    public init(description: String, category: Logger.Category = .performance, file: String = #file, function: String = #function, line: Int = #line) {
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.description = description
        self.category = category
        self.file = file
        self.function = function
        self.line = line
        Logger.debug("⏱ \(description) - Started", category: category, file: file, function: function, line: line)
    }

    public func checkpoint(_ label: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        Logger.debug("⏱ \(description) - Checkpoint '\(label)' at \(String(format: "%.4f", elapsed))s",
                   category: category, file: file, function: function, line: line)
    }

    deinit {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        Logger.debug("⏱ \(description) - Finished in \(String(format: "%.4f", elapsed))s",
                   category: category, file: file, function: function, line: line)
    }
}

// MARK: - Cache

/// Synchronous, thread-safe cache of `os.Logger` instances.
private final class LoggerCache: @unchecked Sendable {
    static let shared = LoggerCache()

    private var loggers: [Logger.Category: os.Logger] = [:]
    private let lock = NSLock()

    func logger(for category: Logger.Category) -> os.Logger {
        lock.lock()
        defer { lock.unlock() }
        if let cached = loggers[category] { return cached }
        let new = os.Logger(subsystem: Logger.Category.subsystem, category: category.rawValue)
        loggers[category] = new
        return new
    }
}
