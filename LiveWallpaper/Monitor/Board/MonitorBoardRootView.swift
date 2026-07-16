import SwiftUI
import LiveWallpaperCore

// MARK: - Monitor v2 board root view
//
// The SwiftUI board that IS the wallpaper's content layer. Transparent
// background (the desktop picture shows behind); non-edit mode is completely
// passive — no hover chrome, no gestures. Edit mode adds per-widget hover
// controls, the magnetic ghost frame ("背影方框"), alignment guides, and an
// add-widget catalog. Visuals are restrained plain SwiftUI shapes; a later wave
// restyles with the shared component library.

// MARK: - Board clock

/// The board's single clock: 1 Hz normally, STOPPED while the wallpaper is
/// suspended. `.periodic` has no off switch — it keeps scheduling vsync work for
/// a board nobody is looking at — so suspending ends the schedule after one
/// entry instead. That one entry still fires, giving the final frame an accurate
/// `now` rather than a frozen-at-suspend clock; TimelineView then requests
/// nothing further until `suspended` flips back and a fresh schedule is built.
struct MonitorBoardClock: TimelineSchedule {
    let suspended: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let suspended = self.suspended
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = suspended ? nil : current.addingTimeInterval(1)
            return current
        }
    }
}

struct MonitorBoardRootView: View {
    @ObservedObject var model: MonitorBoardInteractionModel
    @ObservedObject var data: MonitorBoardDataModel
    /// Observe the rolling history so widget bodies re-render when new samples
    /// land (the store is @Published inside the data model).
    @ObservedObject private var history: MonitorHistoryStore
    @Environment(\.monitorReduceMotion) private var reduceMotion
    @Environment(\.monitorSuspended) private var suspended
    @FocusState private var boardFocused: Bool

    /// The Add Widget button's board-space frame, reported by the toolbar so the
    /// catalog anchors beneath it. `.zero` until the toolbar first lays out.
    @State private var addButtonFrame: CGRect = .zero

    /// When true, every tile renders as a name-only placeholder (icon + widget
    /// name) instead of the live instrument. The inspector preview sets this so
    /// arranging the board never pumps live data; the wallpaper leaves it false.
    private let nameOnlyTiles: Bool

    init(model: MonitorBoardInteractionModel, data: MonitorBoardDataModel, nameOnlyTiles: Bool = false) {
        self.model = model
        self.data = data
        self.history = data.historyStore
        self.nameOnlyTiles = nameOnlyTiles
    }

    var body: some View {
        // ONE board-level 1 Hz clock drives `now` for every tile (time-based
        // widgets read it via `context.now`); there is no per-tile or per-widget
        // Timer, so a full board refreshes on a single tick instead of a dozen
        // independent ones. The tick only changes `now` — view identity is stable,
        // so charts don't re-animate. While suspended the clock stops entirely.
        TimelineView(MonitorBoardClock(suspended: suspended)) { timeline in
            boardContent(now: timeline.date)
        }
        .background(Color.clear)
        .focusable(model.isEditing)
        .focused($boardFocused)
        .onMoveCommand(perform: handleMoveCommand)
        .onDeleteCommand {
            model.deleteSelectedWidget()
        }
        .onAppear { boardFocused = model.isEditing }
        .onChange(of: model.isEditing) { _, editing in
            boardFocused = editing
        }
    }

    @ViewBuilder
    private func boardContent(now: Date) -> some View {
        GeometryReader { proxy in
            let boardSize = proxy.size
            let geometry = MonitorBoardGeometry(
                boardSize: boardSize,
                referenceWidth: model.referenceWidth,
                topInsetFraction: model.topInsetFraction
            )

            ZStack(alignment: .topLeading) {
                // Transparent hit surface: taps on empty space deselect / exit
                // catalog in edit mode. Non-edit mode: nothing here reacts.
                Color.clear
                    .contentShape(Rectangle())
                    .modifier(EmptyTapModifier(model: model))

                if !geometry.isDegenerate {
                    // Empty-board whisper (SPEC §3.3): a quiet centered hint that
                    // teaches how to start, never a nag. Fades out once a tile lands.
                    if model.placements.isEmpty {
                        emptyBoardHint(boardSize: boardSize)
                    }

                    // Alignment guides + ghost frame sit under the dragged tile
                    // but over the resting tiles.
                    if model.isEditing, let drag = model.drag {
                        guideLayer(drag: drag, geometry: geometry)
                        ghostFrame(drag: drag, geometry: geometry)
                    }

                    ForEach(model.placements) { placement in
                        widgetTile(placement, geometry: geometry, boardSize: boardSize, now: now)
                    }

                    if model.isEditing {
                        editControls(geometry: geometry, boardSize: boardSize)
                    }
                }
            }
            .frame(width: boardSize.width, height: boardSize.height, alignment: .topLeading)
            .coordinateSpace(name: MonitorBoardCoordinateSpace.name)
            .onPreferenceChange(MonitorAddButtonFrameKey.self) { addButtonFrame = $0 }
            .onAppear { model.reflow(boardSize: boardSize) }
            .onChange(of: boardSize) { _, newSize in model.reflow(boardSize: newSize) }
        }
    }

    // MARK: Empty-board hint

    /// Centered low-contrast hint shown only while the board holds no widgets.
    /// Passive (never intercepts events); disappears the moment a tile is added.
    private func emptyBoardHint(boardSize: CGSize) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(MonitorBoardStrings.emptyBoardHint)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .frame(width: min(boardSize.width - 24, 320))
        .position(x: boardSize.width / 2, y: boardSize.height / 2)
        .allowsHitTesting(false)
        .zIndex(2)
    }

    // MARK: Widget tiles

    @ViewBuilder
    private func widgetTile(
        _ placement: MonitorWidgetPlacement,
        geometry: MonitorBoardGeometry,
        boardSize: CGSize,
        now: Date
    ) -> some View {
        let restRawRect = rawRect(placement, geometry: geometry)
        let isDragging = model.drag?.widgetID == placement.id
        // While dragging, the tile follows the pointer's free origin (the ghost
        // shows the snapped target separately); otherwise it rests at its rect.
        let liveRawRect = isDragging ? draggedRawRect(placement, geometry: geometry) : restRawRect
        let liveRenderRect = geometry.renderRect(forRawRect: liveRawRect)

        // `now` is supplied by the single board-level TimelineView; time-based
        // widgets read it via `context.now`, non-time widgets ignore it. No inner
        // per-tile Timer.
        tileBody(placement: placement, cornerRadius: geometry.cornerRadius, renderHeight: liveRenderRect.height, now: now)
            .frame(width: liveRenderRect.width, height: liveRenderRect.height)
            .modifier(SelectionChrome(
                isEditing: model.isEditing,
                isSelected: model.selectedID == placement.id,
                isDragging: isDragging,
                cornerRadius: geometry.cornerRadius
            ))
            .offset(x: liveRenderRect.minX, y: liveRenderRect.minY)
            .zIndex(isDragging ? 40 : 3)
            .allowsHitTesting(model.isEditing)
            .modifier(WidgetDragModifier(
                model: model,
                placement: placement,
                geometry: geometry,
                restRawRect: restRawRect
            ))
            .modifier(MonitorPlacementAccessibilityActions(
                model: model,
                placementID: placement.id
            ))
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            model.moveSelectedWidget(.left)
        case .right:
            model.moveSelectedWidget(.right)
        case .up:
            model.moveSelectedWidget(.up)
        case .down:
            model.moveSelectedWidget(.down)
        @unknown default:
            break
        }
    }

    /// The tile's inner content: the live instrument, or — in name-only preview
    /// mode — an icon+name placeholder. All the placement chrome (frame, selection,
    /// drag) is applied by the caller uniformly regardless of which body this is.
    @ViewBuilder
    private func tileBody(
        placement: MonitorWidgetPlacement,
        cornerRadius: CGFloat,
        renderHeight: CGFloat,
        now: Date
    ) -> some View {
        if nameOnlyTiles {
            MonitorWidgetNameTile(kind: placement.kind, cellHeight: renderHeight, cornerRadius: cornerRadius)
        } else {
            MonitorWidgetFactory.tile(
                context: MonitorWidgetContext(
                    snapshot: data.snapshot,
                    history: history.current,
                    placement: placement,
                    isEditing: model.isEditing,
                    isAgentFleetEnabled: model.isAgentFleetEnabled,
                    reduceMotion: reduceMotion,
                    now: now
                ),
                cornerRadius: cornerRadius
            )
        }
    }

    private func rawRect(_ placement: MonitorWidgetPlacement, geometry: MonitorBoardGeometry) -> CGRect {
        let origin = MonitorBoardLayoutEngine.pixelOrigin(
            normalized: CGPoint(x: placement.x, y: placement.y), boardSize: geometry.boardSize
        )
        let footprint = geometry.pixelSize(for: placement.kind, size: placement.size)
        // Render-side safety clamp: persisted coords normalized against another
        // aspect's reference grid can overflow until `reflow` lands; drawing
        // never leaves the board while the stored values stay untouched.
        return CGRect(origin: geometry.clampOrigin(origin, footprint: footprint), size: footprint)
    }

    private func draggedRawRect(_ placement: MonitorWidgetPlacement, geometry: MonitorBoardGeometry) -> CGRect {
        guard let drag = model.drag else { return rawRect(placement, geometry: geometry) }
        return CGRect(origin: drag.freeOrigin, size: drag.footprint)
    }

    // MARK: Ghost frame ("背影方框") + guides

    @ViewBuilder
    private func ghostFrame(drag: MonitorBoardDragState, geometry: MonitorBoardGeometry) -> some View {
        if let ghostOrigin = drag.ghostOrigin {
            let raw = CGRect(origin: ghostOrigin, size: drag.footprint)
            let rect = geometry.renderRect(forRawRect: raw)
            RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                .fill(Color(red: 0.85, green: 0.66, blue: 0.30).opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                        .strokeBorder(Color(red: 0.82, green: 0.63, blue: 0.30).opacity(0.5), lineWidth: 1)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .zIndex(6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func guideLayer(drag: MonitorBoardDragState, geometry: MonitorBoardGeometry) -> some View {
        let draggedRect = CGRect(origin: drag.snappedOrigin ?? drag.freeOrigin, size: drag.footprint)
        ZStack {
            if let guide = drag.guideX {
                guideLine(guide, draggedRect: draggedRect, geometry: geometry)
            }
            if let guide = drag.guideY {
                guideLine(guide, draggedRect: draggedRect, geometry: geometry)
            }
        }
        .zIndex(6)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func guideLine(
        _ guide: MonitorSnapGuide,
        draggedRect: CGRect,
        geometry: MonitorBoardGeometry
    ) -> some View {
        let seg = MonitorBoardLayoutEngine.guideSegment(guide, draggedRect: draggedRect, geometry: geometry)
        Path { path in
            path.move(to: seg.start)
            path.addLine(to: seg.end)
        }
        .stroke(Color(red: 0.80, green: 0.62, blue: 0.30).opacity(0.55), lineWidth: 1)
    }

    // MARK: Edit controls (floating per-widget + catalog)

    @ViewBuilder
    private func editControls(geometry: MonitorBoardGeometry, boardSize: CGSize) -> some View {
        // Top-centre toolbar (Add Widget + Done): the exit affordance the
        // menu-entered edit mode needs, plus the entry point to the add catalog
        // (mock `.topbar`). Placed via a board-sized top-aligned frame + top inset
        // rather than `.position`, so the Add button's reported frame stays
        // accurate for anchoring the catalog. The inset clears the menu bar on the
        // full-screen overlay yet stays light on small preview boards.
        MonitorBoardEditToolbar(model: model)
            .padding(.top, toolbarTopInset(boardHeight: boardSize.height))
            .frame(width: boardSize.width, height: boardSize.height, alignment: .top)
            .zIndex(70)

        // Per-widget control bar (size + settings + remove), floating around the
        // selected tile and always fully clamped into the board. Hidden mid-drag.
        if let selectedID = model.selectedID,
           let placement = model.placements.first(where: { $0.id == selectedID }),
           model.drag == nil {
            let render = geometry.renderRect(forRawRect: rawRect(placement, geometry: geometry))
            MonitorWidgetControlBar(model: model, placement: placement)
                .fixedSize()
                .modifier(ControlBarPlacement(
                    anchorRect: render,
                    boardSize: boardSize,
                    estimatedSize: Self.controlBarEstimate(for: placement.kind)
                ))
                .zIndex(60)
        }

        // Settings card, anchored beside the widget whose gear is open, clamped
        // into the board. Hidden mid-drag.
        if let settingsID = model.settingsOpenID,
           let placement = model.placements.first(where: { $0.id == settingsID }),
           model.drag == nil {
            let render = geometry.renderRect(forRawRect: rawRect(placement, geometry: geometry))
            MonitorWidgetSettingsCard(model: model, placement: placement, maxHeight: boardSize.height - 16)
                .modifier(SettingsCardPlacement(anchorRect: render, boardSize: boardSize))
                .zIndex(80)
        }

        // Add-widget catalog: a KNOWN width directly beneath the Add Widget
        // button; the grid's height is budgeted so the panel bottom stays inside
        // the board. Placement is fully deterministic — visible frame 1.
        if model.isCatalogOpen {
            let catalogWidth = min(760, boardSize.width * 0.86)
            let anchor = catalogAnchorFrame(boardSize: boardSize)
            let scrollCap = catalogScrollCap(anchorMaxY: anchor.maxY, boardHeight: boardSize.height)
            MonitorCatalogView(model: model, maxScrollHeight: scrollCap)
                .frame(width: catalogWidth)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(CatalogBelowPlacement(
                    anchorFrame: anchor,
                    boardSize: boardSize,
                    panelWidth: catalogWidth,
                    estimatedHeight: scrollCap + 64
                ))
                .zIndex(75)
        }
    }

    /// Control-bar size estimate for its pre-measurement placement: gear + trash
    /// (~68pt) plus ~30pt per size segment. Only the first frame's centring
    /// depends on it — the measured size takes over immediately.
    private static func controlBarEstimate(for kind: MonitorWidgetKind) -> CGSize {
        let count = kind.allowedSizes.count
        return CGSize(width: 68 + (count > 1 ? CGFloat(count) * 30 + 16 : 0), height: 36)
    }

    /// Height budget for the catalog's scrolling grid: ≤55% board height and
    /// never past the board's bottom margin (64pt covers the panel's header +
    /// padding). Floored so tiny preview boards still get a usable strip.
    private func catalogScrollCap(anchorMaxY: CGFloat, boardHeight: CGFloat) -> CGFloat {
        max(min(boardHeight * 0.55, boardHeight - anchorMaxY - 16 - 64), 80)
    }

    /// Top inset for the edit toolbar. A full-screen board (the wallpaper overlay
    /// sits under the menu bar) needs a ≥44pt top edge to clear it; a small
    /// inspector-preview board uses a light proportional inset so the toolbar
    /// doesn't eat its limited height. Board height is the proxy for which case.
    private func toolbarTopInset(boardHeight: CGFloat) -> CGFloat {
        boardHeight >= 500 ? min(max(boardHeight * 0.035, 44), 60) : boardHeight * 0.055
    }

    /// Frame the catalog anchors beneath: the Add Widget button once reported,
    /// else a top-centre fallback just under where the toolbar sits.
    private func catalogAnchorFrame(boardSize: CGSize) -> CGRect {
        if addButtonFrame != .zero { return addButtonFrame }
        let inset = toolbarTopInset(boardHeight: boardSize.height)
        return CGRect(x: boardSize.width / 2 - 40, y: inset, width: 80, height: 30)
    }
}

// MARK: - Empty-space tap

/// Double-click on empty board space toggles edit mode (mock: `dblclick →
/// toggleEdit`); a single click in edit mode deselects + closes the catalog. The
/// double-click handler is attached first so it wins the gesture arbitration.
private struct EmptyTapModifier: ViewModifier {
    @ObservedObject var model: MonitorBoardInteractionModel

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) {
                model.setEditing(!model.isEditing)
            }
            .onTapGesture {
                guard model.isEditing else { return }
                model.select(nil)
                model.isCatalogOpen = false
                model.settingsOpenID = nil
            }
    }
}

// MARK: - Selection / hover chrome

/// Edit-mode chrome: a hairline highlight on hover/selection, a lift shadow
/// while dragging. Non-edit mode adds nothing.
private struct SelectionChrome: ViewModifier {
    let isEditing: Bool
    let isSelected: Bool
    let isDragging: Bool
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(borderOverlay)
            .shadow(
                color: Color.black.opacity(isDragging ? 0.55 : 0),
                radius: isDragging ? 28 : 0, x: 0, y: isDragging ? 16 : 0
            )
            .scaleEffect(isEditing && hovering && !isDragging ? 1.0 : 1.0)
            .onHover { if isEditing { hovering = $0 } }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isEditing && (isSelected || isDragging || hovering) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color(red: 0.62, green: 0.5, blue: 0.28).opacity(isSelected || isDragging ? 0.55 : 0.3),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Floating-panel placement
//
// All three edit-mode panels (control bar, settings card, catalog) place
// deterministically: a top-leading `.offset` computed from the anchor plus a
// KNOWN width (catalog, settings card) or a size estimate (control bar), both
// axes clamped on-board. Panels are visible from their very first frame —
// placement never waits on a measure→preference→state round-trip (the previous
// hidden-until-measured design stayed at opacity 0 forever when that round
// trip didn't complete). A background size reader refines the estimate once
// real geometry lands; a missed refinement costs a few points of centring,
// never visibility.

/// Clamp a left edge so a panel of `width` stays `margin` inside a `span`-wide
/// board. Panels wider than the board centre (never pushed negative).
private func clampPanelLeft(_ left: CGFloat, width: CGFloat, span: CGFloat, margin: CGFloat) -> CGFloat {
    let maxLeft = span - width - margin
    guard margin <= maxLeft else { return max((span - width) / 2, 0) }
    return min(max(left, margin), maxLeft)
}

/// Clamp a top edge so a panel of `height` stays `margin` inside a `span`-tall
/// board (top-anchored). Panels taller than the board pin to the top margin.
private func clampPanelTop(_ top: CGFloat, height: CGFloat, span: CGFloat, margin: CGFloat) -> CGFloat {
    let maxTop = max(span - height - margin, margin)
    return min(max(top, margin), maxTop)
}

/// The control bar: centred above the widget, flipping below when there's no
/// room, then tucking just inside the widget's top edge as a last resort. Both
/// axes are clamped so the whole bar stays on-board.
private struct ControlBarPlacement: ViewModifier {
    let anchorRect: CGRect
    let boardSize: CGSize
    let estimatedSize: CGSize
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let size = measured ?? estimatedSize
        let margin: CGFloat = 6
        let gap: CGFloat = 8
        var top = anchorRect.minY - size.height - gap
        if top < margin {
            let below = anchorRect.maxY + gap
            top = (below + size.height <= boardSize.height - margin) ? below : anchorRect.minY + gap
        }
        let left = clampPanelLeft(anchorRect.midX - size.width / 2, width: size.width, span: boardSize.width, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: clampPanelTop(top, height: size.height, span: boardSize.height, margin: margin))
    }
}

/// The settings card: preferred to the right of the widget, flipping left when
/// it would overflow, top-aligned with the widget. Width is the card's known
/// constant; the measured height refines the bottom clamp.
private struct SettingsCardPlacement: ViewModifier {
    let anchorRect: CGRect
    let boardSize: CGSize
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let size = measured ?? CGSize(width: MonitorWidgetSettingsCard.cardWidth, height: 340)
        let margin: CGFloat = 8
        let gap: CGFloat = 8
        var left = anchorRect.maxX + gap
        if left + size.width > boardSize.width - margin {
            let toLeft = anchorRect.minX - gap - size.width
            left = toLeft >= margin ? toLeft : boardSize.width - size.width - margin
        }
        left = clampPanelLeft(left, width: size.width, span: boardSize.width, margin: margin)
        let top = clampPanelTop(anchorRect.minY, height: size.height, span: boardSize.height, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: top)
    }
}

/// The catalog: ~8pt beneath the Add Widget button, horizontally centred on it.
/// Width and height budget come from the caller, so placement is fully
/// deterministic; the measured height only refines the bottom clamp.
private struct CatalogBelowPlacement: ViewModifier {
    let anchorFrame: CGRect
    let boardSize: CGSize
    let panelWidth: CGFloat
    let estimatedHeight: CGFloat
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        let height = measured?.height ?? estimatedHeight
        let margin: CGFloat = 8
        let left = clampPanelLeft(anchorFrame.midX - panelWidth / 2, width: panelWidth, span: boardSize.width, margin: margin)
        let top = clampPanelTop(anchorFrame.maxY + 8, height: height, span: boardSize.height, margin: margin)
        return content
            .modifier(MonitorPanelSizeReader(size: $measured))
            .offset(x: left, y: top)
    }
}
