import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore

/// Live drag state for the widget currently under the pointer. Held only while
/// a drag is in flight; mutating it never writes config (persistence happens on
/// drag-end via the model's edit callback).
struct MonitorBoardDragState: Equatable {
    var widgetID: UUID
    /// Pointer offset inside the widget at grab time, so the ghost tracks 1:1.
    var grabOffset: CGSize
    var footprint: CGSize
    /// Free (raw) top-left the pointer maps to this frame.
    var freeOrigin: CGPoint
    /// Snapped origin when magnetic snap is engaged this frame (nil under ⌘).
    var snappedOrigin: CGPoint?
    var guideX: MonitorSnapGuide?
    var guideY: MonitorSnapGuide?
    /// The origin to restore if the drop finds no legal spot.
    var originAtGrab: CGPoint
    var didMove: Bool

    /// Where the ghost frame ("背影方框") should draw: the snapped target when
    /// snapping, otherwise nil (no ghost under raw / ⌘ drag).
    var ghostOrigin: CGPoint? { snappedOrigin }
}

/// Observable board state driving `MonitorBoardRootView`: the placements, edit
/// mode, selection, and the in-flight drag. This is the single writer of the
/// board configuration; every committing mutation funnels through
/// `emitConfiguration()` so the host can debounce persistence.
@MainActor
final class MonitorBoardInteractionModel: ObservableObject {
    @Published private(set) var placements: [MonitorWidgetPlacement]
    @Published var isEditing: Bool = false
    @Published var selectedID: UUID?
    @Published private(set) var drag: MonitorBoardDragState?
    /// True when the catalog popover is open (edit mode only).
    @Published var isCatalogOpen: Bool = false
    /// The widget whose settings card is open (edit mode only). Cleared on
    /// edit-exit, drag-start, removal, and empty-space tap.
    @Published var settingsOpenID: UUID?

    /// Current board pixel size; the view sets this from its geometry reader so
    /// the model can resolve normalized placements to pixels for hit-free math.
    @Published var boardSize: CGSize = .zero

    /// Normalized top forbidden zone (menu-bar avoidance) the host sets; folded
    /// into every `geometry` so clamp / snap / reflow keep widgets below the
    /// menu bar. 0 on hosts (e.g. no matching NSScreen) that don't set it.
    var topInsetFraction: CGFloat = 0

    /// Whether AI-agent widget kinds are offered in the catalog (Pro gate).
    let isAgentFleetEnabled: Bool

    /// Fired with a persistence-ready configuration after a committing edit
    /// (drag-end, add, remove, resize) — never per mouse-move. The host wires
    /// this to debounced persistence.
    var onConfigurationEdited: ((MonitorBoardConfiguration) -> Void)?

    /// Fired whenever edit mode toggles (menu-driven, the board's own Done, or
    /// Esc). The host relays it so the wallpaper can force mouse interaction on
    /// while editing and restore the persisted click-through state on exit.
    var onEditingChanged: ((Bool) -> Void)?

    private var baseConfiguration: MonitorBoardConfiguration

    init(configuration: MonitorBoardConfiguration, isAgentFleetEnabled: Bool) {
        self.baseConfiguration = configuration
        self.placements = configuration.widgets
        self.isAgentFleetEnabled = isAgentFleetEnabled
    }

    var geometry: MonitorBoardGeometry {
        MonitorBoardGeometry(
            boardSize: boardSize,
            columns: baseConfiguration.gridColumns,
            topInsetFraction: topInsetFraction
        )
    }

    /// Kinds offered in the add catalog: all cases, minus agent-fleet kinds when
    /// that feature is locked.
    var catalogKinds: [MonitorWidgetKind] {
        MonitorWidgetKind.allCases.filter { isAgentFleetEnabled || !$0.requiresAgentFleet }
    }

    // MARK: - External config application

    /// Replace the whole board from a new configuration (live config change).
    /// Cancels any in-flight drag and drops selection that no longer exists.
    func apply(configuration: MonitorBoardConfiguration) {
        baseConfiguration = configuration
        placements = configuration.widgets
        drag = nil
        if let selectedID, !placements.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if let settingsOpenID, !placements.contains(where: { $0.id == settingsOpenID }) {
            self.settingsOpenID = nil
        }
        // Externally applied placements may be normalized against another
        // aspect's reference grid; clamp them onto the live board. The view's
        // onAppear only covers the first attach — a live config swap lands here
        // with no onAppear re-fire.
        if boardSize != .zero {
            reflow(boardSize: boardSize)
        }
    }

    // MARK: - Geometry helpers

    func footprint(for placement: MonitorWidgetPlacement) -> CGSize {
        geometry.pixelSize(for: placement.kind, size: placement.size)
    }

    func pixelOrigin(for placement: MonitorWidgetPlacement) -> CGPoint {
        MonitorBoardLayoutEngine.pixelOrigin(
            normalized: CGPoint(x: placement.x, y: placement.y), boardSize: boardSize
        )
    }

    /// Current rect of every placement, optionally excluding one id — the
    /// sibling set the engine sees during a drag / resolve.
    private func items(excluding excludedID: UUID?) -> [MonitorBoardItem] {
        placements.compactMap { placement in
            guard placement.id != excludedID else { return nil }
            return MonitorBoardItem(
                id: placement.id,
                rect: CGRect(origin: pixelOrigin(for: placement), size: footprint(for: placement))
            )
        }
    }

    // MARK: - Selection

    func select(_ id: UUID?) {
        selectedID = id
    }

    func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        if !editing {
            selectedID = nil
            isCatalogOpen = false
            settingsOpenID = nil
            drag = nil
        }
        onEditingChanged?(editing)
    }

    // MARK: - Drag lifecycle

    func beginDrag(_ id: UUID, grabOffset: CGSize) {
        guard isEditing, let placement = placements.first(where: { $0.id == id }) else { return }
        select(id)
        isCatalogOpen = false
        settingsOpenID = nil
        let origin = pixelOrigin(for: placement)
        drag = MonitorBoardDragState(
            widgetID: id,
            grabOffset: grabOffset,
            footprint: footprint(for: placement),
            freeOrigin: origin,
            snappedOrigin: nil,
            guideX: nil,
            guideY: nil,
            originAtGrab: origin,
            didMove: false
        )
    }

    /// Update the in-flight drag for a pointer location (board coordinates).
    /// `bypassSnap` mirrors ⌘/⌥ held — raw drag, no ghost, no guides.
    func updateDrag(pointInBoard point: CGPoint, bypassSnap: Bool) {
        guard var current = drag else { return }
        let free = CGPoint(
            x: point.x - current.grabOffset.width,
            y: point.y - current.grabOffset.height
        )
        if hypot(free.x - current.originAtGrab.x, free.y - current.originAtGrab.y) > 4 {
            current.didMove = true
        }
        current.freeOrigin = free

        if bypassSnap {
            current.snappedOrigin = nil
            current.guideX = nil
            current.guideY = nil
        } else {
            let result = MonitorBoardLayoutEngine.snap(
                freeOrigin: free,
                footprint: current.footprint,
                geometry: geometry,
                items: items(excluding: current.widgetID),
                ignoring: current.widgetID
            )
            current.snappedOrigin = result.snapped ? result.origin : nil
            current.guideX = result.guideX
            current.guideY = result.guideY
        }
        drag = current
    }

    /// Finish the drag. Pure click (no move) restores in place; otherwise lands
    /// at the snapped/free origin resolved for overlap, springing back on no
    /// legal spot. Commits + emits config only when the origin actually changed.
    func endDrag(bypassSnap: Bool) {
        guard let current = drag else { return }
        drag = nil
        guard current.didMove else { return }

        let snapped = bypassSnap ? nil : current.snappedOrigin
        let landed = MonitorBoardLayoutEngine.land(
            freeOrigin: current.freeOrigin,
            snappedOrigin: snapped,
            footprint: current.footprint,
            geometry: geometry,
            items: items(excluding: current.widgetID),
            ignoring: current.widgetID
        ) ?? current.originAtGrab

        guard let index = placements.firstIndex(where: { $0.id == current.widgetID }) else { return }
        let normalized = MonitorBoardLayoutEngine.normalized(pixelOrigin: landed, boardSize: boardSize)
        let changed = placements[index].x != normalized.x || placements[index].y != normalized.y
        placements[index].x = normalized.x
        placements[index].y = normalized.y
        if changed { emitConfiguration() }
    }

    // MARK: - Add / remove / resize

    /// Add a widget of `kind` at its first-fit free position. No-op (returns
    /// false) if the board is full or the kind is gated off.
    @discardableResult
    func addWidget(kind: MonitorWidgetKind) -> Bool {
        guard isEditing else { return false }
        guard isAgentFleetEnabled || !kind.requiresAgentFleet else { return false }
        let size = Self.defaultSize(for: kind)
        let footprintSize = geometry.pixelSize(for: kind, size: size)
        guard let origin = MonitorBoardLayoutEngine.firstFit(
            footprint: footprintSize, geometry: geometry, items: items(excluding: nil)
        ) else {
            return false
        }
        let normalized = MonitorBoardLayoutEngine.normalized(pixelOrigin: origin, boardSize: boardSize)
        let placement = MonitorWidgetPlacement(kind: kind, size: size, x: normalized.x, y: normalized.y)
        placements.append(placement)
        select(placement.id)
        isCatalogOpen = false
        emitConfiguration()
        return true
    }

    func removeWidget(_ id: UUID) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements.remove(at: index)
        if selectedID == id { selectedID = nil }
        if settingsOpenID == id { settingsOpenID = nil }
        emitConfiguration()
    }

    /// Whole-placement writeback from the settings card (`onUpdate`). A size
    /// change routes through the `setSize` refit path so the board never overlaps;
    /// if the resize can't be placed the size stays put but the other edits
    /// (options, etc.) still apply. Same-size edits replace the fields in place,
    /// keeping the widget's stored position.
    func updateWidget(_ updated: MonitorWidgetPlacement) {
        guard let index = placements.firstIndex(where: { $0.id == updated.id }) else { return }
        let current = placements[index]

        if updated.size != current.size {
            // Land non-size edits first (old size + position), then attempt the
            // resize. On success `setSize` emits; on denial we emit the options.
            var applied = updated
            applied.size = current.size
            applied.x = current.x
            applied.y = current.y
            placements[index] = applied
            if !setSize(updated.id, to: updated.size) {
                emitConfiguration()
            }
            return
        }

        var applied = updated
        applied.x = current.x
        applied.y = current.y
        placements[index] = applied
        emitConfiguration()
    }

    /// Toggle a widget between S and M, re-fitting around its anchor. Returns
    /// false (and leaves the widget untouched) when the new size can't be
    /// placed — the view flashes a "deny" on false.
    @discardableResult
    func setSize(_ id: UUID, to size: MonitorWidgetSize) -> Bool {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return false }
        // Reject sizes the kind doesn't allow (e.g. processes is medium-only).
        guard placements[index].kind.allowedSizes.contains(size) else { return false }
        guard placements[index].size != size else { return true }
        let anchor = pixelOrigin(for: placements[index])
        let newFootprint = geometry.pixelSize(for: placements[index].kind, size: size)
        guard let origin = MonitorBoardLayoutEngine.refitForSizeChange(
            anchor: anchor, newFootprint: newFootprint, geometry: geometry,
            items: items(excluding: id), ignoring: id
        ) else {
            return false
        }
        let normalized = MonitorBoardLayoutEngine.normalized(pixelOrigin: origin, boardSize: boardSize)
        placements[index].size = size
        placements[index].x = normalized.x
        placements[index].y = normalized.y
        emitConfiguration()
        return true
    }

    // MARK: - Reflow on board resize

    /// Re-clamp + de-overlap every placement after a board size change (mock
    /// `relayoutAll`). Normalized origins survive; only clamped/nudged widgets
    /// move. Does not emit config — reflow is derived, not a user edit.
    func reflow(boardSize newSize: CGSize) {
        boardSize = newSize
        guard !geometry.isDegenerate else { return }
        let geo = geometry

        // Pass 1: clamp each normalized origin onto the new board.
        for index in placements.indices {
            let footprintSize = geo.pixelSize(for: placements[index].kind, size: placements[index].size)
            let px = MonitorBoardLayoutEngine.pixelOrigin(
                normalized: CGPoint(x: placements[index].x, y: placements[index].y), boardSize: newSize
            )
            let clamped = geo.clampOrigin(px, footprint: footprintSize)
            let normalized = MonitorBoardLayoutEngine.normalized(pixelOrigin: clamped, boardSize: newSize)
            placements[index].x = normalized.x
            placements[index].y = normalized.y
        }

        // Pass 2: legalize any resize-induced overlaps.
        for index in placements.indices {
            let footprintSize = geo.pixelSize(for: placements[index].kind, size: placements[index].size)
            let px = MonitorBoardLayoutEngine.pixelOrigin(
                normalized: CGPoint(x: placements[index].x, y: placements[index].y), boardSize: newSize
            )
            let rect = CGRect(origin: px, size: footprintSize)
            if !MonitorBoardLayoutEngine.isLegal(
                rect: rect, geometry: geo, items: items(excluding: placements[index].id),
                ignoring: placements[index].id
            ) {
                if let resolved = MonitorBoardLayoutEngine.resolve(
                    origin: px, footprint: footprintSize, geometry: geo,
                    items: items(excluding: placements[index].id), ignoring: placements[index].id,
                    maxDisplacement: .greatestFiniteMagnitude
                ) {
                    let normalized = MonitorBoardLayoutEngine.normalized(pixelOrigin: resolved, boardSize: newSize)
                    placements[index].x = normalized.x
                    placements[index].y = normalized.y
                }
            }
        }
    }

    // MARK: - Config emission

    private func emitConfiguration() {
        baseConfiguration.widgets = placements
        onConfigurationEdited?(baseConfiguration)
    }

    var currentConfiguration: MonitorBoardConfiguration {
        var config = baseConfiguration
        config.widgets = placements
        return config
    }

    /// Default size for a newly added widget: small when the kind allows it and
    /// reads well at 2×2, otherwise the first allowed size. Fleet-style kinds
    /// (fleet, processes) read poorly small, so they prefer medium. Honors the
    /// kind's `allowedSizes` in all cases.
    static func defaultSize(for kind: MonitorWidgetKind) -> MonitorWidgetSize {
        let allowed = kind.allowedSizes
        let prefersMedium: Bool
        switch kind {
        case .fleet, .processes: prefersMedium = true
        default: prefersMedium = false
        }
        if prefersMedium, allowed.contains(.medium) { return .medium }
        if allowed.contains(.small) { return .small }
        return allowed.first ?? .medium
    }
}
