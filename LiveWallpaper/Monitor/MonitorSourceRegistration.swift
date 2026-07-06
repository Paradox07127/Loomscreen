import Foundation

/// Account-level usage rollup a source can optionally expose. Composed by
/// `MonitorRuntime` because no single source owns the cross-provider total.
protocol MonitorUsageProviding: Sendable {
    func currentUsage() async -> MonitorProviderUsage
}

extension ClaudeAgentSource: MonitorUsageProviding {}
extension CodexAgentSource: MonitorUsageProviding {}

enum MonitorSourceRegistration {
    @MainActor private static var registered = false

    /// One store for every source across pipeline rebuilds, and the handle the
    /// app's termination path flushes so the debounce window can't drop the
    /// last cursor updates on quit.
    static let sharedCursorStore = MonitorTailCursorStore()

    static func flushCursorStoreForTermination() {
        sharedCursorStore.flush()
    }

    /// Idempotent; must run on the main actor before the first
    /// `MonitorRuntime.acquire` so agent sources participate in the pipeline.
    @MainActor static func registerDefaultFactories() {
        guard !registered else { return }
        registered = true
        MonitorRuntime.extraSourceFactories.append { options in
            guard options.agents else { return [] }
            let cursorStore = sharedCursorStore
            var sources: [any MonitorDataSource] = []
            if let root = options.claudeRoot {
                sources.append(ClaudeAgentSource(rootURL: root, cursorStore: cursorStore))
            }
            if let root = options.codexRoot {
                sources.append(CodexAgentSource(rootURL: root, cursorStore: cursorStore))
            }
            return sources
        }
    }
}
