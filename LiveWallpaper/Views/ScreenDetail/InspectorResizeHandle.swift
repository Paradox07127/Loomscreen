import AppKit
import SwiftUI

/// Vertical handle on the inspector's leading edge for click-drag width
/// resizing. Visually disappears when idle to keep the inspector reading
/// quiet, but leaves a 1pt hairline divider so users can still see "there's
/// an edge here." The full capsule + material affordance fades in on hover
/// or while dragging — mirroring Xcode / Final Cut's inspector divider.
///
/// `NSCursor.resizeLeftRight` is pushed while the cursor sits inside the
/// 28pt hit area regardless of visual state — that's the primary discovery
/// signal. `onDisappear` pops the cursor if the view leaves while still
/// hovered to avoid stranding it on the stack.
struct InspectorResizeHandle: View {
    static let hitAreaWidth: CGFloat = 28

    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onPreviewWidthChange: (CGFloat) -> Void
    let onCommitWidth: (CGFloat) -> Void
    /// When non-nil, dragging until the (clamped) candidate width drops below
    /// this value arms a close: releasing there fires `onRequestClose` instead
    /// of committing a width. Pairs with a lower `minWidth` from the parent so
    /// the panel can visibly shrink into a sliver before it lets go.
    var closeThreshold: CGFloat? = nil
    var onRequestClose: (() -> Void)? = nil

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

            // Idle: 1pt hairline that signals "edge here" without dominating.
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: handleHeight * hairlineHeightRatio)
                .opacity(isActive ? 0 : 1)

            // Hover / drag: full capsule affordance with material + stroke.
            // Once the drag is armed to close (pulled into the sliver zone), it
            // switches to an accent capsule and grows so "let go to close" reads
            // clearly — distinct from an ordinary resize.
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
                    let candidate = clamped(start - value.translation.width)
                    setClosingArmed(armed(for: candidate))
                    onPreviewWidthChange(candidate)
                }
                .onEnded { value in
                    let start = dragStartWidth ?? width
                    let candidate = clamped(start - value.translation.width)
                    if armed(for: candidate), let onRequestClose {
                        onRequestClose()
                    } else {
                        onCommitWidth(candidate)
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

    /// Whether releasing at `candidate` should collapse the panel rather than
    /// commit a width. Only ever true when the parent wired up drag-to-close.
    private func armed(for candidate: CGFloat) -> Bool {
        guard let closeThreshold, onRequestClose != nil else { return false }
        return candidate < closeThreshold
    }

    private func setClosingArmed(_ value: Bool) {
        guard isClosingArmed != value else { return }
        isClosingArmed = value
    }

    private func clamped(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidth)
    }
}
