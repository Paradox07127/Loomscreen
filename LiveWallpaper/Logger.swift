import Foundation
import os

final class Logger {
    // MARK: - Log Categories

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

        static let subsystem = "com.livewallpaper"

        /// Backing `os.Logger` for this category, lazily created and cached.
        /// `os.Logger` is a thin wrapper but caching avoids the per-call
        /// subsystem string interning.
        fileprivate var logger: os.Logger {
            LoggerCache.shared.logger(for: self)
        }
    }

    // MARK: - Log Levels

    enum Level {
        case debug, info, notice, warning, error, fault

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

    static func log(
        _ message: String,
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
        // Swift `os.Logger` keeps the level-aware short-circuit: when the
        // system log level disables a category, the formatted string is never
        // built. Privacy is `.public` so console output matches the legacy
        // `os_log("%{public}@", ...)` behavior.
        category.logger.log(
            level: level.osLogType,
            "\(level.prefix, privacy: .public) [\(fileName, privacy: .public):\(line, privacy: .public)] \(function, privacy: .public) - \(message, privacy: .public)"
        )
    }

    // MARK: - Convenience Methods

    static func debug(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    static func info(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .info, file: file, function: function, line: line)
    }

    static func notice(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .notice, file: file, function: function, line: line)
    }

    static func warning(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .warning, file: file, function: function, line: line)
    }

    static func error(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .error, file: file, function: function, line: line)
    }

    static func fault(_ message: String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, category: category, level: .fault, file: file, function: function, line: line)
    }

    // MARK: - Lifecycle Logging

    static func functionStart(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Started", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    static func functionEnd(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Finished", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    // MARK: - Domain-Specific Logging

    static func videoLoaded(url: URL, screenID: UInt32, file: String = #file, function: String = #function, line: Int = #line) {
        log("Video loaded: \(url.lastPathComponent) for screen \(screenID)", category: .videoPlayer, level: .info, file: file, function: function, line: line)
    }

    static func screensDetected(_ count: Int, file: String = #file, function: String = #function, line: Int = #line) {
        log("Detected \(count) screens", category: .screenManager, level: .notice, file: file, function: function, line: line)
    }

    static func powerSourceChanged(isOnBattery: Bool, level: Double?, file: String = #file, function: String = #function, line: Int = #line) {
        let source = isOnBattery ? "battery" : "AC power"
        var message = "Power source changed to \(source)"
        if let level = level, isOnBattery {
            message += " (level: \(Int(level * 100))%)"
        }
        log(message, category: .powerMonitor, level: .notice, file: file, function: function, line: line)
    }

    static func settingsChanged(setting: String, value: Any, file: String = #file, function: String = #function, line: Int = #line) {
        log("Setting changed: \(setting) = \(value)", category: .settings, level: .info, file: file, function: function, line: line)
    }
}

// MARK: - Performance Measuring

class PerformanceTimer {
    private let startTime: CFAbsoluteTime
    private let description: String
    private let category: Logger.Category
    private let file: String
    private let function: String
    private let line: Int

    init(description: String, category: Logger.Category = .performance, file: String = #file, function: String = #function, line: Int = #line) {
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.description = description
        self.category = category
        self.file = file
        self.function = function
        self.line = line
        Logger.debug("⏱ \(description) - Started", category: category, file: file, function: function, line: line)
    }

    func checkpoint(_ label: String) {
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
