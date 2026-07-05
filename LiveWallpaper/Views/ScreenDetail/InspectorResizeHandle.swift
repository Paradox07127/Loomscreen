import AppKit
import SwiftUI

/// Vertical handle on the inspector's leading edge for click-drag width
/// resizing. Idle = 1pt hairline only; the full capsule affordance fades in
/// on hover/drag.
///
/// `NSCursor.resizeLeftRight` is pushed while the cursor sits inside the 28pt
/// hit area regardless of visual state. `onDisappear` pops the cursor if the
/// view leaves while still hovered to avoid stranding it on the stack.
struct InspectorResizeHandle: View {
    static let hitAreaWidth: CGFloat = 28

    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onPreviewWidthChange: (CGFloat) -> Void
    let onCommitWidth: (CGFloat) -> Void
    /// When non-nil, dragging until the raw candidate width drops below
    /// this value arms a close: releasing there fires `onRequestClose` instead
    /// of committing a width. The preview width remains clamped at `minWidth`
    /// so the panel does not crop its contents while the close is armed.
    var closeThreshold: CGFloat?
    var onRequestClose: (() -> Void)?

    private let handleWidth: CGFloat = 6
    private let handleHeight: CGFloat = 52
    private let hairlineHeightRatio: CGFloat = 0.7

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var isClosingArmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: handleHeight * hairlineHeightRatio)
                .opacity(isActive ? 0 : 1)

            // When armed to close (pulled into the sliver zone) the capsule
            // switches to accent + grows so "let go to close" reads distinct
            // from an ordinary resize.
            Capsule()
                .fill(isClosingArmed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isClosingArmed ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.28),
                            lineWidth: 0.75
                        )
                )
                .frame(width: handleWidth, height: isClosingArmed ? handleHeight + 18 : handleHeight)
                .shadow(
                    color: isClosingArmed ? Color.accentColor.opacity(0.45) : Color.black.opacity(0.08),
                    radius: isClosingArmed ? 7 : 5, x: 0, y: 2
                )
                .opacity(isActive ? 0.95 : 0)
                .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.16)), value: isClosingArmed)
        }
        .frame(width: Self.hitAreaWidth)
        .frame(maxHeight: .infinity)
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.16)), value: isActive)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? width
                    if dragStartWidth == nil {
                        dragStartWidth = start
                    }
                    isDragging = true
                    let rawCandidate = rawCandidate(start: start, translationWidth: value.translation.width)
                    setClosingArmed(armed(for: rawCandidate))
                    onPreviewWidthChange(clamped(rawCandidate))
                }
                .onEnded { value in
                    let start = dragStartWidth ?? width
                    let rawCandidate = rawCandidate(start: start, translationWidth: value.translation.width)
                    if armed(for: rawCandidate), let onRequestClose {
                        onRequestClose()
                    } else {
                        onCommitWidth(clamped(rawCandidate))
                    }
                    dragStartWidth = nil
                    isDragging = false
                    isClosingArmed = false
                }
        )
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
        .help(Text("Drag to resize properties panel"))
        .accessibilityLabel(Text("Resize properties panel"))
        .accessibilityHint(Text("Drag horizontally to change the properties panel width"))
    }

    private var isActive: Bool {
        isHovering || isDragging
    }

    /// Only ever true when the parent wired up drag-to-close.
    private func armed(for candidate: CGFloat) -> Bool {
        guard let closeThreshold, onRequestClose != nil else { return false }
        return candidate < closeThreshold
    }

    private func setClosingArmed(_ value: Bool) {
        guard isClosingArmed != value else { return }
        isClosingArmed = value
    }

    private func rawCandidate(start: CGFloat, translationWidth: CGFloat) -> CGFloat {
        start - translationWidth
    }

    private func clamped(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidth)
    }
}
