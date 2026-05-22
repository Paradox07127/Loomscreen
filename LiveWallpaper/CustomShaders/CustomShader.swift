#if !LITE_BUILD
import Foundation

/// User-imported Metal shader. Persisted as a single JSON file per shader in
/// `~/Library/Application Support/<bundle>/shaders/` so we never have to
/// reconcile a sidecar `.metal` against a metadata file.
public struct CustomShader: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var author: String?
    public var source: String
    public let createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        author: String? = nil,
        source: String,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.source = source
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }
}

extension CustomShader {
    /// Conservative slug for log lines / error contexts. Never used as a
    /// filesystem name (UUID is).
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
#endif
