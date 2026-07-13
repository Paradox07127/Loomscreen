import Foundation

// MARK: - Monitor widget board configuration
// A free-placement magnetic widget board. Persistence rules mirror the rest of the
// schema layer: decodeIfPresent + defaults so configs round-trip across versions,
// and unknown widget kinds written by a newer build are dropped, never fatal.

public enum MonitorWidgetKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case cpu
    case memory
    case gpu
    case network
    case disk
    case power
    case clock
    case processes
    case health
    case usage
    case fleet
    case aiEngine

    public var id: String { rawValue }

    /// Kinds that surface AI-agent data; the renderer hard-gates these off
    /// unless the injected `FeatureCatalog` enables `.agentFleet` (Pro).
    public var requiresAgentFleet: Bool {
        switch self {
        case .usage, .fleet: return true
        default: return false
        }
    }

    /// Grid footprint in cells (10-column basis; cells are square, so S=1×1 and
    /// L=2×2 render as exact squares, M=2×1 as an exact 2:1, at any board aspect).
    public func cellSize(for size: MonitorWidgetSize) -> (columns: Int, rows: Int) {
        switch size {
        case .small: return (1, 1)
        case .medium: return (2, 1)
        case .large: return (2, 2)
        }
    }

    /// Per-kind size availability, mirrored from the design mock's per-kind
    /// `META` sizes (xl dropped — S/M/L only).
    public var allowedSizes: [MonitorWidgetSize] {
        switch self {
        case .processes, .fleet: return [.medium, .large]
        case .power, .clock, .health: return [.small, .medium]
        default: return [.small, .medium, .large]
        }
    }
}

public enum MonitorWidgetSize: String, Codable, Sendable, CaseIterable {
    case small = "s"
    case medium = "m"
    case large = "l"
}

public enum MonitorWidgetOptionValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case stringList([String])

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var stringListValue: [String]? {
        if case .stringList(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([String].self) {
            self = .stringList(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported monitor widget option value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .stringList(let value): try c.encode(value)
        }
    }
}

/// One widget on the board. `x`/`y` are the top-left corner normalized to the
/// board (0…1); pixel footprint derives from `size` × the board's cell metrics
/// at render time, so placements survive display changes. The renderer clamps
/// out-of-bounds placements back onto the board instead of dropping them.
public struct MonitorWidgetPlacement: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: MonitorWidgetKind
    public var size: MonitorWidgetSize
    public var x: Double
    public var y: Double
    public var options: [String: MonitorWidgetOptionValue]

    public init(
        id: UUID = UUID(),
        kind: MonitorWidgetKind,
        size: MonitorWidgetSize = .medium,
        x: Double = 0,
        y: Double = 0,
        options: [String: MonitorWidgetOptionValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.size = size
        self.x = x.isFinite ? min(max(x, 0), 1) : 0
        self.y = y.isFinite ? min(max(y, 0), 1) : 0
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, size, x, y, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let kind = try c.decode(MonitorWidgetKind.self, forKey: .kind)
        let size = try c.decodeIfPresent(MonitorWidgetSize.self, forKey: .size) ?? .medium
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let options = try c.decodeIfPresent([String: MonitorWidgetOptionValue].self, forKey: .options) ?? [:]
        self.init(id: id, kind: kind, size: size, x: x, y: y, options: options)
    }
}

public struct MonitorBoardConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var gridColumns: Int
    public var widgets: [MonitorWidgetPlacement]
    /// Data-push cadence; renderer clamps to 0.2…2 Hz regardless of persistence.
    public var refreshHz: Double
    /// When true the wallpaper stops being click-through so the board can receive
    /// clicks (widget editing / dragging) instead of passing them to the desktop.
    public var mouseInteractionEnabled: Bool
    public var reduceMotionOverride: Bool?

    public static let currentSchemaVersion = 4
    public static let defaultGridColumns = 10
    public static let `default` = MonitorBoardConfiguration()

    /// Renderer-facing clamp for the data-push cadence (0.2…2 Hz), independent
    /// of what is persisted.
    public static func clampedRefreshHz(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0.2), 2.0)
    }

    public init(
        schemaVersion: Int = MonitorBoardConfiguration.currentSchemaVersion,
        gridColumns: Int = MonitorBoardConfiguration.defaultGridColumns,
        widgets: [MonitorWidgetPlacement]? = nil,
        refreshHz: Double = 1.0,
        mouseInteractionEnabled: Bool = false,
        reduceMotionOverride: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.gridColumns = max(gridColumns, 1)
        self.widgets = widgets ?? Self.defaultSystemPlacements()
        self.refreshHz = Self.clampedRefreshHz(refreshHz)
        self.mouseInteractionEnabled = mouseInteractionEnabled
        self.reduceMotionOverride = reduceMotionOverride
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, gridColumns, widgets, refreshHz, mouseInteractionEnabled, reduceMotionOverride
    }

    /// Always consumes exactly one unkeyed element so a failed placement decode
    /// (e.g. unknown kind from a newer build) skips that element instead of
    /// corrupting the rest of the array.
    private struct LossyPlacement: Decodable {
        let value: MonitorWidgetPlacement?
        init(from decoder: Decoder) {
            value = try? MonitorWidgetPlacement(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        gridColumns = max(try c.decodeIfPresent(Int.self, forKey: .gridColumns) ?? Self.defaultGridColumns, 1)
        let lossy = try c.decodeIfPresent([LossyPlacement].self, forKey: .widgets)
        widgets = lossy.map { $0.compactMap(\.value) } ?? Self.defaultSystemPlacements()
        refreshHz = Self.clampedRefreshHz(
            try c.decodeIfPresent(Double.self, forKey: .refreshHz) ?? 1.0
        )
        mouseInteractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .mouseInteractionEnabled) ?? false
        reduceMotionOverride = try c.decodeIfPresent(Bool.self, forKey: .reduceMotionOverride)

        // v4: normalize the grid column density to the current default (10;
        // earlier builds shipped 12 then 8). x/y stay 0…1 normalized, so no
        // coordinate rewrite — the renderer's reflow/clamp absorbs the change.
        if schemaVersion < 4 {
            gridColumns = Self.defaultGridColumns
            schemaVersion = 4
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(gridColumns, forKey: .gridColumns)
        try c.encode(widgets, forKey: .widgets)
        try c.encode(refreshHz, forKey: .refreshHz)
        try c.encode(mouseInteractionEnabled, forKey: .mouseInteractionEnabled)
        try c.encodeIfPresent(reduceMotionOverride, forKey: .reduceMotionOverride)
    }
}

// MARK: Board decode + default layout

extension MonitorBoardConfiguration {
    /// Decode a persisted board config from a keyed slot (e.g.
    /// `ScreenConfiguration.savedMonitorConfiguration` / `WallpaperContent`'s
    /// nested `config`). Returns `nil` when the key is genuinely absent — so the
    /// caller keeps its own default — or when the payload is present but corrupt
    /// (the board decoder is all-`decodeIfPresent`, so `try?` yields `nil` rather
    /// than silently fabricating a default board over the user's real layout).
    public static func decodeIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) -> MonitorBoardConfiguration? {
        guard container.contains(key) else { return nil }
        return try? container.decode(MonitorBoardConfiguration.self, forKey: key)
    }

    /// Three mediums (2 cols each) occupy the bottom row's left 6 of 10
    /// columns, left-anchored.
    static let defaultSystemKinds: [(MonitorWidgetKind, MonitorWidgetSize)] = [
        (.cpu, .medium), (.memory, .medium), (.gpu, .medium),
    ]

    public static func defaultSystemPlacements() -> [MonitorWidgetPlacement] {
        packedPlacements(for: defaultSystemKinds)
    }

    /// Packs widgets into bottom-anchored rows (left→right, bottom→up) on a
    /// 10-column grid, assuming a 16:10 reference board; the renderer's clamp
    /// + magnetic snap absorb other aspect ratios. Positions are cell-exact —
    /// visual gutters between tiles are the renderer's job (per-tile inset),
    /// so a full 10-column row ends exactly at x=1.
    public static func packedPlacements(
        for kinds: [(MonitorWidgetKind, MonitorWidgetSize)]
    ) -> [MonitorWidgetPlacement] {
        let columns = Self.defaultGridColumns
        let referenceAspect = 16.0 / 10.0
        let cellW = 1.0 / Double(columns)
        // Cells are square: the renderer sets cellHeight = cellWidth, so a cell's
        // normalized height on the 16:10 reference board is aspect/columns
        // (cellH_px = aspect/columns × H = 1/columns × W = cellW_px).
        let cellH = referenceAspect / Double(columns)
        let bottomMargin = 0.02

        var placements: [MonitorWidgetPlacement] = []
        var row: [(MonitorWidgetKind, MonitorWidgetSize)] = []
        var rowCells = 0
        var bottomY = 1.0 - bottomMargin

        func flushRow() {
            guard !row.isEmpty else { return }
            let rowRows = row.map { $0.0.cellSize(for: $0.1).rows }.max() ?? 1
            let height = Double(rowRows) * cellH
            var cellX = 0
            for (kind, size) in row {
                let cells = kind.cellSize(for: size)
                placements.append(MonitorWidgetPlacement(
                    kind: kind, size: size,
                    x: Double(cellX) * cellW, y: bottomY - height
                ))
                cellX += cells.columns
            }
            bottomY -= height
            row = []
            rowCells = 0
        }

        for (kind, size) in kinds {
            let cells = kind.cellSize(for: size)
            if rowCells + cells.columns > columns { flushRow() }
            row.append((kind, size))
            rowCells += cells.columns
        }
        flushRow()
        return placements
    }
}
