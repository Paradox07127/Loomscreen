import Foundation

/// Static model-id → context-window map used to derive `contextUsedPercent`.
///
/// Keyed by model-id *prefix* so a family (`claude-opus-4`, `gpt-5`) covers all
/// its point releases without per-version churn. An unknown prefix returns nil so
/// context pressure is never fabricated for a model whose window we can't verify.
///
/// Window values are the model's INPUT context window (the denominator for
/// input + cache-read tokens), not the max output — consistent with how the
/// fleet derives "how full is the conversation".
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

    // Anthropic families all ship a 200K context window today. Codex/OpenAI
    // models observed in ~/.codex fixtures are the gpt-5 family (e.g. "gpt-5.5",
    // "codex-auto-review") plus the o-series; gpt-5 family carries a 272K input
    // window, o-series 200K. Bare "opus"/"sonnet"/"haiku" aliases also appear in
    // transcripts and map to the same 200K Anthropic window.
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
        // OpenAI / Codex.
        Entry(prefix: "gpt-5", window: 272_000),
        Entry(prefix: "codex-", window: 272_000),   // codex-auto-review et al. (gpt-5 family)
        Entry(prefix: "codex", window: 272_000),
        Entry(prefix: "o4", window: 200_000),
        Entry(prefix: "o3", window: 200_000),
        Entry(prefix: "o1", window: 200_000),
    ]
}
