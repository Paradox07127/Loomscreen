import AppKit
import SwiftUI
import LiveWallpaperCore

// MARK: - Widget drag gesture
//
// Drives the interaction model from a SwiftUI drag. ⌘/⌥ held bypasses snapping
// (Apple's escape valve) — SwiftUI drags don't carry modifier state, so we read
// `NSEvent.modifierFlags` live. The gesture only mutates interaction state; no
// config write happens until drag-end (via the model).

struct WidgetDragModifier: ViewModifier {
    @ObservedObject var model: MonitorBoardInteractionModel
    let placement: MonitorWidgetPlacement
    let geometry: MonitorBoardGeometry
    /// The tile's resting raw rect, used to compute the pointer grab offset.
    let restRawRect: CGRect

    func body(content: Content) -> some View {
        content.gesture(dragGesture, including: model.isEditing ? .all : .subviews)
    }

    private var bypassSnap: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.command) || flags.contains(.option)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(MonitorBoardCoordinateSpace.name))
            .onChanged { value in
                if model.drag?.widgetID != placement.id {
                    // Grab offset = pointer position within the RENDERED rect, so
                    // the tile tracks the cursor without jumping.
                    let render = geometry.renderRect(forRawRect: restRawRect)
                    let offset = CGSize(
                        width: value.startLocation.x - render.minX,
                        height: value.startLocation.y - render.minY
                    )
                    // Convert the render-relative grab to a raw-relative grab so
                    // the model's free-origin math (raw rects) lines up.
                    let rawOffset = CGSize(
                        width: offset.width + geometry.tileInsetX,
                        height: offset.height + geometry.tileInsetY
                    )
                    model.beginDrag(placement.id, grabOffset: rawOffset)
                }
                model.updateDrag(pointInBoard: value.location, bypassSnap: bypassSnap)
            }
            .onEnded { _ in
                model.endDrag(bypassSnap: bypassSnap)
            }
    }
}

/// Named coordinate space so gesture locations are board-relative regardless of
/// where the tile sits.
enum MonitorBoardCoordinateSpace {
    static let name = "MonitorBoard"
}

// MARK: - Floating control bar (size toggle + settings + remove)

/// Per-widget edit controls that float around the selected tile: an S/M/L size
/// segmented control (driven by `kind.allowedSizes`), a settings button, and a
/// remove button. Restrained styling; the shared library restyles later. The
/// placement modifier keeps the whole bar inside the board on every edge.
struct MonitorWidgetControlBar: View {
    @ObservedObject var model: MonitorBoardInteractionModel
    let placement: MonitorWidgetPlacement
    @State private var denied = false

    var body: some View {
        HStack(spacing: 8) {
            sizeSegment
            settingsButton
            removeButton
        }
        .padding(4)
        .background(
            Capsule(style: .continuous).fill(Color(white: 0.14).opacity(0.95))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .offset(x: denied ? -4 : 0)
        .animation(denied ? .default : nil, value: denied)
    }

    @ViewBuilder
    private var sizeSegment: some View {
        // Only the kind's allowed sizes (e.g. processes is medium-only). A single
        // allowed size means no toggle is useful, so the segment is hidden.
        let allowed = placement.kind.allowedSizes
        if allowed.count > 1 {
            HStack(spacing: 2) {
                ForEach(allowed, id: \.self) { size in
                    Button {
                        if !model.setSize(placement.id, to: size) { flashDeny() }
                    } label: {
                        // Size code ("S" / "M" / "L") — technical notation, identical
                        // in every language, so rendered verbatim (not catalogued).
                        Text(verbatim: size.rawValue.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(placement.size == size ? Color.white : Color.white.opacity(0.45))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(placement.size == size ? Color(white: 0.3) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.black.opacity(0.3)))
        }
    }

    private var settingsButton: some View {
        let isOpen = model.settingsOpenID == placement.id
        return Button {
            model.settingsOpenID = isOpen ? nil : placement.id
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOpen ? Color.white : Color.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(white: isOpen ? 0.28 : 0.14)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(MonitorBoardStrings.widgetSettings)
        .accessibilityLabel(Text(MonitorBoardStrings.widgetSettings))
    }

    private var removeButton: some View {
        Button {
            model.perform(.delete(id: placement.id))
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(white: 0.14)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(MonitorBoardStrings.removeWidget)
    }

    private func flashDeny() {
        denied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { denied = false }
    }
}

// MARK: - Edit toolbar (add + done)

/// The board's own edit-mode toolbar: a top-centre pill merging an "Add Widget"
/// button that opens the catalog and a "Done" button that exits edit mode (the
/// exit affordance the menu-entered edit mode needs). Restrained dark chrome
/// matching the floating control bar; the shared library restyles later. The Add
/// button publishes its board-space frame so the catalog can anchor beneath it.
struct MonitorBoardEditToolbar: View {
    @ObservedObject var model: MonitorBoardInteractionModel

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.isCatalogOpen.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text(MonitorBoardStrings.addWidget)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(model.isCatalogOpen ? Color.white : Color.white.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(model.isCatalogOpen ? Color(white: 0.32) : Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help(MonitorBoardStrings.addWidget)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MonitorAddButtonFrameKey.self,
                        value: proxy.frame(in: .named(MonitorBoardCoordinateSpace.name))
                    )
                }
            )

            Button {
                model.setEditing(false)
            } label: {
                Text(MonitorBoardStrings.doneEditing)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help(MonitorBoardStrings.doneEditing)
        }
        .padding(4)
        .background(
            Capsule(style: .continuous).fill(Color(white: 0.13).opacity(0.95))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Add-widget catalog

/// Minimal catalog panel listing the available widget kinds (gated kinds hidden
/// when the fleet feature is off). Clicking a kind places it at the first-fit
/// free position. The grid scrolls inside a capped height so the panel never
/// overruns the board; the caller anchors it beneath the Add Widget button.
struct MonitorCatalogView: View {
    @ObservedObject var model: MonitorBoardInteractionModel
    /// Upper bound on the scrolling grid's height (mock: `max-height: 56vh`); the
    /// grid takes its natural height up to this, then scrolls.
    let maxScrollHeight: CGFloat
    // Unmeasured ⇒ cap at maxScrollHeight (never collapse to 0); the measured
    // content height then shrinks the region to fit sparse grids.
    @State private var contentSize: CGSize?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(MonitorBoardStrings.widgetCatalog)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                Spacer()
                Button {
                    model.isCatalogOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.catalogKinds) { kind in
                        catalogItem(kind)
                    }
                }
                .modifier(MonitorPanelSizeReader(size: $contentSize))
            }
            .frame(height: min(contentSize?.height ?? .greatestFiniteMagnitude, maxScrollHeight))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.11).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func catalogItem(_ kind: MonitorWidgetKind) -> some View {
        Button {
            model.addWidget(kind: kind)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(white: 0.17))
                    .frame(height: 44)
                    .overlay(
                        Text(MonitorWidgetFactory.displayName(kind))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                    )
                HStack(spacing: 4) {
                    Text(MonitorWidgetFactory.displayName(kind))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Spacer(minLength: 0)
                    if kind.requiresAgentFleet {
                        Text(MonitorBoardStrings.proBadge)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Color(red: 0.85, green: 0.7, blue: 0.35))
                    }
                }
                // Allowed size codes ("S · M · L") — technical notation, verbatim.
                Text(verbatim: kind.allowedSizes.map { $0.rawValue.uppercased() }.joined(separator: " · "))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(white: 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel size reader

/// Reports the modified view's size into a binding. Refinement only — callers
/// place from a known/estimated size first, so an unreported size can never
/// leave a panel invisible or unplaced.
struct MonitorPanelSizeReader: ViewModifier {
    @Binding var size: CGSize?

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { size = proxy.size }
                    .onChange(of: proxy.size) { size = $1 }
            }
        )
    }
}

// MARK: - Settings card

/// The board's inline settings card: the shared `MonitorWidgetSettingsPopover`
/// (native controls — size picker, kind-specific options, remove) wrapped in a
/// dark material so it stays legible floating over the wallpaper/overlay. Edits
/// route back through the interaction model (`updateWidget` handles the resize
/// refit; the placement command handles removal). Forced dark so the native controls
/// render light-on-dark regardless of the desktop appearance. Width is fixed
/// (`cardWidth`, matching the popover's own frame) so the board can place the
/// card deterministically; content taller than `maxHeight` scrolls internally.
struct MonitorWidgetSettingsCard: View {
    @ObservedObject var model: MonitorBoardInteractionModel
    let placement: MonitorWidgetPlacement
    /// Height budget from the board; content beyond it scrolls.
    let maxHeight: CGFloat

    /// Matches `MonitorWidgetSettingsPopover`'s fixed frame — the known width
    /// deterministic placement relies on.
    static let cardWidth: CGFloat = MonitorWidgetSettingsPopover.preferredWidth

    @State private var contentSize: CGSize?

    var body: some View {
        ScrollView {
            MonitorWidgetSettingsPopover(
                placement: placement,
                onUpdate: { model.updateWidget($0) },
                onRemove: { model.perform(.delete(id: placement.id)) }
            )
            .modifier(MonitorPanelSizeReader(size: $contentSize))
        }
        .frame(
            width: Self.cardWidth,
            height: min(contentSize?.height ?? 340, max(maxHeight, 120))
        )
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.12).opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 14)
        .environment(\.colorScheme, .dark)
    }
}

/// Destructive accessibility actions are exposed only while the board is in
/// edit mode. The action carries the tile identity directly, so VoiceOver can
/// never delete a different selected sibling.
struct MonitorPlacementAccessibilityActions: ViewModifier {
    @ObservedObject var model: MonitorBoardInteractionModel
    let placementID: UUID

    @ViewBuilder
    func body(content: Content) -> some View {
        if model.isEditing {
            content.accessibilityAction(named: Text(MonitorBoardStrings.removeWidget)) {
                model.perform(.delete(id: placementID))
            }
        } else {
            content
        }
    }
}

// MARK: - Board-chrome layout preference keys

/// The Add Widget button's frame in the board coordinate space, so the catalog
/// can anchor directly beneath it. Reduce ignores the `.zero` default siblings
/// emit, so the real value always wins.
struct MonitorAddButtonFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - User-facing strings (centralized catalog keys)
//
// Every string is a `LocalizedStringKey`, so `Text(key)` / `.help(key)` resolve
// through the app's string catalog (all four languages). "PRO" reads identically
// in every language but is catalogued for a uniform, complete table.

enum MonitorBoardStrings {
    // Computed (not stored) so the enum stays Sendable under strict concurrency —
    // each access yields a fresh `LocalizedStringKey`.
    static var addWidget: LocalizedStringKey { "Add Widget" }
    static var removeWidget: LocalizedStringKey { "Remove" }
    static var widgetSettings: LocalizedStringKey { "Widget Settings" }
    static var widgetCatalog: LocalizedStringKey { "Widget Catalog" }
    static var proBadge: LocalizedStringKey { "PRO" }
    static var boardFull: LocalizedStringKey { "Board full — no free space" }
    static var editLayout: LocalizedStringKey { "Edit Layout" }
    static var doneEditing: LocalizedStringKey { "Done" }
    static var emptyBoardHint: LocalizedStringKey { "Double-click to edit, then add instruments from the catalog" }
}
