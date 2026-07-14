import SwiftUI
import AppKit

/// Apple Music-style playlist row.
///
/// Drag-reorder is attached **only to the leading-handle hit area** (28×44pt),
/// not the whole row, so the body's tap "play now" gesture and the context
/// menu don't race the DragGesture.
struct PlaylistRow: View {
    let entry: PlaylistEntry
    let index: Int
    let isBeingDragged: Bool
    let onSetPrimary: () -> Void
    let onPlayNow: () -> Void
    let onRemove: () -> Void

    /// Parent owns the reorder state machine; the row only forwards the
    /// translation + pointer coordinates upward.
    let onDragChanged: (_ translationY: CGFloat, _ locationY: CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var metadata: PlaylistRowMetadata = .empty
    @State private var isHovering = false
    @State private var isHandleHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 10) {
            leadingHandle
                .frame(width: 28, height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named(playlistCoordSpaceName))
                        .onChanged { value in
                            onDragChanged(value.translation.height, value.location.y)
                        }
                        .onEnded { _ in
                            onDragEnded()
                        }
                )
                .onHover { hovering in
                    guard isHandleHovering != hovering else { return }
                    isHandleHovering = hovering
                    if hovering {
                        (isBeingDragged ? NSCursor.closedHand : NSCursor.openHand).push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onChange(of: isBeingDragged) { _, dragging in
                    // Swap open-hand ↔ closed-hand cursor when a drag of the
                    // hovered handle starts/ends.
                    guard isHandleHovering else { return }
                    NSCursor.pop()
                    (dragging ? NSCursor.closedHand : NSCursor.openHand).push()
                }
                .onDisappear {
                    if isHandleHovering {
                        NSCursor.pop()
                        isHandleHovering = false
                    }
                }

            AsyncRowThumbnail(bookmark: entry.bookmark)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.name)
                    .font(entry.isPlaying ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: entry.name))

                Text(verbatim: metadata.subtitle)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            trailingControls
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 50)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(strokeColor, lineWidth: strokeWidth)
        )
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowOffset)
        .offset(y: hoverLiftOffset)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onPlayNow() }
        .contextMenu { rowMenuItems }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Unnamed action binds VoiceOver's default "double-tap to activate";
        // `.onTapGesture(count: 2)` isn't an accessibility action so without
        // this the row would have no primary activation.
        .accessibilityAction { onPlayNow() }
        .accessibilityAction(named: Text("Set as Primary")) { onSetPrimary() }
        .accessibilityAction(named: Text("Play Now")) { onPlayNow() }
        .accessibilityAction(named: Text("Remove")) { onRemove() }
        .task(id: entry.bookmark) {
            let loaded = await PlaylistMetadataService.shared.metadata(for: entry.bookmark)
            guard !Task.isCancelled else { return }
            metadata = loaded
        }
    }

    private var hoverLiftOffset: CGFloat {
        guard isHovering, !isBeingDragged, !reduceMotion else { return 0 }
        return -1.5
    }

    /// Shared by the right-click context menu and the trailing ellipsis menu
    /// so the two can't drift.
    @ViewBuilder
    private var rowMenuItems: some View {
        Button("Set as Primary", systemImage: "star.fill", action: onSetPrimary)
            .disabled(entry.isPrimary)
        Button("Play Now", systemImage: "play.fill", action: onPlayNow)
            .disabled(entry.isPlaying)
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
    }

    // MARK: - Leading slot

    @ViewBuilder
    private var leadingHandle: some View {
        if entry.isPlaying {
            EQPulseBar(isPlaying: true)
        } else {
            RowNumberHandle(index: index + 1, showHandle: isHovering || isHandleHovering || isBeingDragged)
                .help(Text("Drag to reorder"))
        }
    }

    // MARK: - Trailing slot

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: 4) {
            if entry.isPrimary {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 18, height: 18)
                    .help(Text("Primary entry"))
            }

            RowOverflowMenu(isHovering: isHovering) {
                rowMenuItems
            }
        }
    }

    // MARK: - Visual style

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(backgroundFill)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovering)
    }

    private var backgroundFill: Color {
        if entry.isPlaying { return Color.accentColor.opacity(0.10) }
        if isBeingDragged { return Color.primary.opacity(0.08) }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }

    private var strokeColor: Color {
        if isBeingDragged { return Color.accentColor.opacity(0.55) }
        if entry.isPlaying { return Color.accentColor.opacity(0.30) }
        return .clear
    }

    private var strokeWidth: CGFloat {
        (isBeingDragged || entry.isPlaying) ? 1 : 0
    }

    private var shadowColor: Color {
        guard !reduceTransparency else { return .clear }
        if isBeingDragged { return Color.black.opacity(0.22) }
        if isHovering { return Color.black.opacity(0.08) }
        return .clear
    }

    private var shadowRadius: CGFloat {
        if isBeingDragged { return 10 }
        if isHovering { return 6 }
        return 0
    }

    private var shadowOffset: CGFloat {
        if isBeingDragged { return 4 }
        if isHovering { return 2 }
        return 0
    }

    private var accessibilityLabel: Text {
        var components: [String] = [entry.name]
        if !metadata.subtitle.isEmpty {
            components.append(metadata.subtitle)
        }
        if entry.isPrimary {
            components.append(String(localized: "Primary entry", defaultValue: "Primary entry", comment: "VoiceOver tag for the starred playlist entry."))
        }
        if entry.isPlaying {
            components.append(String(localized: "Now playing", defaultValue: "Now playing", comment: "VoiceOver tag for the currently playing playlist entry."))
        }
        return Text(verbatim: components.joined(separator: ", "))
    }
}
