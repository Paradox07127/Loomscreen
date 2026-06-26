import SwiftUI
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI

/// Interactive 24h timeline. Edits are commit-on-drag-end via
/// `onCommitTimeChange`; on parent rejection the preview unwinds back to
/// the stored hours automatically because rendering is sourced from
/// `slots`, not the in-flight drag delta.
struct ScheduleTimelineEditor: View {
    let slots: [ScheduleSlot]
    let currentHour: Int
    let palette: [Color]
    let onCommitTimeChange: (_ slotID: UUID, _ start: Int, _ end: Int) -> Void
    let onRequestInsert: (_ startHour: Int) -> Void

    @State private var drag: TimelineDragSession?

    private let majorHours: [Int] = [0, 6, 12, 18, 24]
    private let trackHeight: CGFloat = 16
    private let handleWidth: CGFloat = 8
    private let visualHandleWidth: CGFloat = 3

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let hourWidth = width / 24
                ZStack(alignment: .topLeading) {
                    background
                    minorTicks(width: width)
                    majorTicks(width: width)

                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        slotView(
                            slot: slot,
                            accent: palette[index % palette.count],
                            hourWidth: hourWidth
                        )
                    }

                    cursor(width: width)
                }
                .contentShape(Rectangle())
                // Anchor gestures to a stable named space: a `.local` gesture
                // on the moving segment would drift with its own `.offset(...)`,
                // creating a feedback loop on every render.
                .coordinateSpace(name: timelineCoordSpaceName)
                .onTapGesture(count: 2) { location in
                    handleDoubleTap(at: location, hourWidth: hourWidth)
                }
            }
            .frame(height: trackHeight + 14)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))

            hourLabels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Background + ticks

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
            .fill(Color.primary.opacity(0.06))
    }

    @ViewBuilder
    private func minorTicks(width: CGFloat) -> some View {
        ForEach(0..<25, id: \.self) { hour in
            if !majorHours.contains(hour) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 0.5, height: 5)
                    .offset(x: CGFloat(hour) / 24.0 * width, y: 0)
            }
        }
    }

    @ViewBuilder
    private func majorTicks(width: CGFloat) -> some View {
        ForEach(majorHours, id: \.self) { hour in
            Rectangle()
                .fill(Color.primary.opacity(0.24))
                .frame(width: 0.5, height: 10)
                .offset(x: CGFloat(hour) / 24.0 * width, y: 0)
        }
    }

    @ViewBuilder
    private func cursor(width: CGFloat) -> some View {
        let normalized = ((currentHour % 24) + 24) % 24
        let x = CGFloat(normalized) / 24.0 * width
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: trackHeight + 8)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            .offset(x: x - 1, y: 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var hourLabels: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ForEach(majorHours, id: \.self) { hour in
                let fraction = CGFloat(hour) / 24.0
                let alignment: HorizontalAlignment =
                    (hour == 0) ? .leading : (hour == 24 ? .trailing : .center)
                Text(verbatim: ScheduleTimeFormatter.hourLabel(hour))
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 50,
                        alignment: alignment == .leading
                            ? .leading
                            : (alignment == .trailing ? .trailing : .center)
                    )
                    .offset(
                        x: fraction * width
                            - (alignment == .leading ? 0 : (alignment == .trailing ? 50 : 25)),
                        y: 0
                    )
            }
        }
        .frame(height: 12)
    }

    // MARK: - Slot rendering + drag

    @ViewBuilder
    private func slotView(
        slot: ScheduleSlot,
        accent: Color,
        hourWidth: CGFloat
    ) -> some View {
        let renderHours = displayHours(for: slot)
        let segments = ScheduleSlot(
            id: slot.id,
            startHour: renderHours.start,
            endHour: renderHours.end,
            videoBookmarkData: slot.videoBookmarkData,
            label: slot.label
        ).timelineSegments()

        ForEach(Array(segments.enumerated()), id: \.offset) { offset, segment in
            // Wrap slots whose second half is empty (e.g. 22 → 0) collapse
            // to a single segment after `timelineSegments()` filtering, so
            // the trailing handle must anchor to the LAST segment, not
            // always `offset == 1`. Otherwise midnight-ending slots would
            // render with no draggable trailing edge.
            let isLeadingPart = !segment.wraps || offset == 0
            let isTrailingPart = !segment.wraps || offset == segments.count - 1
            let x = CGFloat(segment.start) * hourWidth
            let w = max(0, CGFloat(segment.end - segment.start) * hourWidth)
            if w > 0 {
                segmentBlock(
                    slot: slot,
                    accent: accent,
                    x: x,
                    width: w,
                    hourWidth: hourWidth,
                    showLeadingHandle: isLeadingPart,
                    showTrailingHandle: isTrailingPart,
                    isPreview: drag?.slotID == slot.id
                )
            }
        }
    }

    /// Live drag preview when this slot is the active drag, else persisted hours.
    private func displayHours(for slot: ScheduleSlot) -> (start: Int, end: Int) {
        if let drag, drag.slotID == slot.id {
            return drag.proposedHours
        }
        return (slot.startHour, slot.endHour)
    }

    @ViewBuilder
    private func segmentBlock(
        slot: ScheduleSlot,
        accent: Color,
        x: CGFloat,
        width: CGFloat,
        hourWidth: CGFloat,
        showLeadingHandle: Bool,
        showTrailingHandle: Bool,
        isPreview: Bool
    ) -> some View {
        let proposedConflict = isPreview && drag?.conflictsKnown == true && drag?.hasConflict == true
        let fill: Color = proposedConflict
            ? DesignTokens.Colors.Status.danger.opacity(0.55)
            : (slot.videoBookmarkData == nil ? accent.opacity(0.45) : accent.opacity(0.70))

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(fill)
                .frame(width: width, height: trackHeight)
                .gesture(translateGesture(for: slot, hourWidth: hourWidth))

            if showLeadingHandle {
                handle(for: slot, edge: .leadingEdge, hourWidth: hourWidth, position: 0)
            }
            if showTrailingHandle {
                handle(
                    for: slot,
                    edge: .trailingEdge,
                    hourWidth: hourWidth,
                    position: width - visualHandleWidth
                )
            }
        }
        .frame(width: width, height: trackHeight, alignment: .topLeading)
        .offset(x: x, y: 14)
    }

    @ViewBuilder
    private func handle(
        for slot: ScheduleSlot,
        edge: TimelineDragSession.Edge,
        hourWidth: CGFloat,
        position: CGFloat
    ) -> some View {
        TimelineEdgeHandle(
            visualWidth: visualHandleWidth,
            hitWidth: handleWidth,
            trackHeight: trackHeight,
            position: position - (handleWidth - visualHandleWidth) / 2,
            gesture: edgeGesture(for: slot, edge: edge, hourWidth: hourWidth)
        )
    }

    // MARK: - Gestures

    private func edgeGesture(
        for slot: ScheduleSlot,
        edge: TimelineDragSession.Edge,
        hourWidth: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(timelineCoordSpaceName))
            .onChanged { value in
                updateDrag(
                    slot: slot,
                    kind: .edge(edge),
                    translationX: value.translation.width,
                    hourWidth: hourWidth
                )
            }
            .onEnded { _ in commitDrag(for: slot) }
    }

    private func translateGesture(for slot: ScheduleSlot, hourWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(timelineCoordSpaceName))
            .onChanged { value in
                updateDrag(
                    slot: slot,
                    kind: .translate,
                    translationX: value.translation.width,
                    hourWidth: hourWidth
                )
            }
            .onEnded { _ in commitDrag(for: slot) }
    }

    private func updateDrag(
        slot: ScheduleSlot,
        kind: TimelineDragSession.Kind,
        translationX: CGFloat,
        hourWidth: CGFloat
    ) {
        guard hourWidth > 0 else { return }
        let deltaHours = Int((translationX / hourWidth).rounded())
        let session = TimelineDragSession(
            slotID: slot.id,
            kind: kind,
            originalStart: slot.startHour,
            originalEnd: slot.endHour,
            deltaHours: deltaHours
        )
        let proposed = session.proposedHours
        let probe = ScheduleSlot(
            id: slot.id,
            startHour: proposed.start,
            endHour: proposed.end,
            label: slot.label
        )
        let otherSlots = slots.filter { $0.id != slot.id }
        let hasConflict = !SchedulePolicy.conflicts(slot: probe, against: otherSlots).isEmpty
        let isZeroLength = proposed.start == proposed.end

        var resolved = session
        resolved.conflictsKnown = true
        resolved.hasConflict = hasConflict || isZeroLength
        drag = resolved
    }

    private func commitDrag(for slot: ScheduleSlot) {
        defer { drag = nil }
        guard let session = drag, session.slotID == slot.id else { return }
        let proposed = session.proposedHours
        let isZeroLength = proposed.start == proposed.end
        let changed = proposed.start != slot.startHour || proposed.end != slot.endHour
        guard changed, !isZeroLength else { return }
        onCommitTimeChange(slot.id, proposed.start, proposed.end)
    }

    private func handleDoubleTap(at location: CGPoint, hourWidth: CGFloat) {
        guard hourWidth > 0 else { return }
        let hour = Int((location.x / hourWidth).rounded(.down))
        guard (0..<24).contains(hour) else { return }
        let occupied = slots.contains { $0.containsHour(hour) }
        guard !occupied else { return }
        onRequestInsert(hour)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: Text {
        let active = slots.first(where: { $0.containsHour(currentHour) })
        let activeLabel = active?.localizedLabel ?? String(
            localized: "no active slot",
            defaultValue: "no active slot",
            comment: "VoiceOver fallback when no schedule slot is currently active."
        )
        let format = String(
            localized: "Schedule timeline, %lld slots, currently %lld:00, active slot: %@",
            defaultValue: "Schedule timeline, %lld slots, currently %lld:00, active slot: %@",
            comment: "VoiceOver label for the schedule timeline bar. Placeholders: slot count, current hour, active slot label."
        )
        return Text(String(format: format, slots.count, currentHour, activeLabel))
    }
}

private let timelineCoordSpaceName = "schedule.timeline.space"

/// Recomputes rendered hours from the original slot + delta, so the
/// source-of-truth never desyncs.
///
/// Edge drags preserve the slot's wrap-mode. Without that, dragging a
/// leading edge across the trailing would flip a 6-hour slot into a
/// 22-hour wrap-around, and `timelineSegments()` would change from one
/// segment to two mid-drag — restructuring `ForEach` and resetting the
/// gesture (jittery, snap-back drag).
///
/// `translate` keeps length constant but `proposedHours` can still wrap
/// across midnight (segment count 1 ↔ 2). If the grabbed segment
/// disappears during the flip, SwiftUI drops the gesture host — a known
/// limitation on multi-hour translates across the midnight boundary.
struct TimelineDragSession: Equatable, Sendable {
    enum Edge: Sendable { case leadingEdge, trailingEdge }
    enum Kind: Equatable, Sendable {
        case edge(Edge)
        case translate
    }

    let slotID: UUID
    let kind: Kind
    let originalStart: Int
    let originalEnd: Int
    var deltaHours: Int
    var conflictsKnown: Bool = false
    var hasConflict: Bool = false

    var proposedHours: (start: Int, end: Int) {
        let normalize = { (h: Int) -> Int in ((h % 24) + 24) % 24 }
        let wasWrap = originalStart > originalEnd

        switch kind {
        case .edge(.leadingEdge):
            let newStart: Int
            if wasWrap {
                // Preserve wrap.
                let minStart = originalEnd + 1
                let maxStart = 23
                newStart = max(minStart, min(maxStart, originalStart + deltaHours))
            } else {
                // Preserve non-wrap.
                let minStart = 0
                let maxStart = originalEnd - 1
                newStart = max(minStart, min(maxStart, originalStart + deltaHours))
            }
            return (newStart, originalEnd)

        case .edge(.trailingEdge):
            let newEnd: Int
            if wasWrap {
                // Preserve wrap.
                let minEnd = 0
                let maxEnd = originalStart - 1
                newEnd = max(minEnd, min(maxEnd, originalEnd + deltaHours))
            } else {
                // Preserve non-wrap. Stopping at 23 (not 24) keeps the slot
                // non-wrap; ending exactly at next-day midnight uses the popover.
                let minEnd = originalStart + 1
                let maxEnd = 23
                newEnd = max(minEnd, min(maxEnd, originalEnd + deltaHours))
            }
            return (originalStart, newEnd)

        case .translate:
            // Length preserved → stable segment count → gesture host doesn't
            // restructure. Wrap may flip; that's fine here.
            return (
                normalize(originalStart + deltaHours),
                normalize(originalEnd + deltaHours)
            )
        }
    }
}

/// Standalone view so the resize cursor `push/pop` balances against an
/// explicit `onDisappear` (matches `PlaylistRow`'s handle pattern). An
/// inline `.onHover` would leak a pushed cursor if the view disappeared
/// while still hovered.
private struct TimelineEdgeHandle<G: Gesture>: View {
    let visualWidth: CGFloat
    let hitWidth: CGFloat
    let trackHeight: CGFloat
    let position: CGFloat
    let gesture: G

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: visualWidth, height: trackHeight - 4)
        }
        .frame(width: hitWidth, height: trackHeight)
        .contentShape(Rectangle())
        .offset(x: position, y: 0)
        .gesture(gesture)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
    }
}
