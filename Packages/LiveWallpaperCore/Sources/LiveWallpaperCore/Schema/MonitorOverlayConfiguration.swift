import Foundation

// MARK: - Monitor overlay configuration
//
// The Monitor widget board as an ADDITIONAL layer that floats over whatever
// wallpaper a display shows — not a wallpaper type of its own. Stored per-screen
// (`ScreenConfiguration.monitorOverlay`) so each display toggles its own board
// independently, exactly as the per-display wallpaper does. Persistence mirrors
// the rest of the schema: decodeIfPresent + defaults so it round-trips across
// versions.

/// Where the overlay window sits in the display's z-order.
public enum MonitorOverlayLevel: String, Codable, Sendable, CaseIterable {
    /// Above the wallpaper but below app windows and desktop icons — a second
    /// desktop ambience layer. Click-through, so desktop icons stay clickable.
    case desktop
    /// Above every app window (status-bar level) — an always-on-top dashboard,
    /// the same z-plane as the Fleet HUD.
    case front
}

public struct MonitorOverlayConfiguration: Codable, Equatable, Sendable {
    /// Master switch for THIS display's overlay. Off by default: the overlay is
    /// opt-in so a fresh install shows only the chosen wallpaper.
    public var enabled: Bool
    /// Z-plane for the overlay window (desktop-layer vs always-on-top).
    public var level: MonitorOverlayLevel
    /// The widget board itself — reused verbatim from the wallpaper board so the
    /// renderer, editor, and gating are identical.
    public var board: MonitorBoardConfiguration

    public static let `default` = MonitorOverlayConfiguration()

    public init(
        enabled: Bool = false,
        level: MonitorOverlayLevel = .desktop,
        board: MonitorBoardConfiguration = .default
    ) {
        self.enabled = enabled
        self.level = level
        self.board = board
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, level, board
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        // Unknown level (e.g. a value written by a newer build) falls back to the
        // desktop default rather than failing the whole overlay decode.
        level = (try? c.decodeIfPresent(MonitorOverlayLevel.self, forKey: .level)) ?? .desktop
        board = try c.decodeIfPresent(MonitorBoardConfiguration.self, forKey: .board) ?? .default
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(level, forKey: .level)
        try c.encode(board, forKey: .board)
    }

    /// Decode a persisted overlay from a keyed slot; `nil` when the key is absent
    /// (caller keeps its own default) or the payload is present but corrupt.
    public static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> MonitorOverlayConfiguration? {
        guard container.contains(key) else { return nil }
        return try? container.decode(MonitorOverlayConfiguration.self, forKey: key)
    }
}
