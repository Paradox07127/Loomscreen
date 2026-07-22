import Foundation

/// Static model-id → context-window map used to derive `contextUsedPercent`.
enum MonitorModelContextCatalog {
    /// Longest-prefix match against the ordered table. Case-insensitive on the
    /// leading ASCII of the model id.
    static func contextWindow(for model: String?) -> Int? {
        guard let model else { return nil }
        let id = model.lowercased()
        // Ordered most-specific-first so e.g. "gpt-5-codex" is matched before a
        // hypothetical shorter "gpt-5" would shadow a different window.
        for entry in table where id.hasPrefix(entry.prefix) {
            return entry.window
        }
        return nil
    }

    private struct Entry {
        let prefix: String
        let window: Int
    }

    private static let table: [Entry] = [
        Entry(prefix: "claude-opus-4", window: 200_000),
        Entry(prefix: "claude-opus", window: 200_000),
        Entry(prefix: "claude-sonnet-4", window: 200_000),
        Entry(prefix: "claude-sonnet-5", window: 200_000),
        Entry(prefix: "claude-sonnet", window: 200_000),
        Entry(prefix: "claude-fable-5", window: 200_000),
        Entry(prefix: "claude-fable", window: 200_000),
        Entry(prefix: "claude-haiku", window: 200_000),
        Entry(prefix: "claude-3-5-sonnet", window: 200_000),
        Entry(prefix: "claude-3-5-haiku", window: 200_000),
        Entry(prefix: "claude-3", window: 200_000),
        Entry(prefix: "opus", window: 200_000),
        Entry(prefix: "sonnet", window: 200_000),
        Entry(prefix: "haiku", window: 200_000),
        Entry(prefix: "gpt-5", window: 272_000),
        Entry(prefix: "codex-", window: 272_000),   // codex-auto-review et al. (gpt-5 family)
        Entry(prefix: "codex", window: 272_000),
        Entry(prefix: "o4", window: 200_000),
        Entry(prefix: "o3", window: 200_000),
        Entry(prefix: "o1", window: 200_000),
    ]
}
