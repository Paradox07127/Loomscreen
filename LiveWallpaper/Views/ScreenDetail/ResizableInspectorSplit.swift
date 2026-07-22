import LiveWallpaperCore
import SwiftUI

/// Pairs a main column with a trailing full-height inspector, resolving widths against the live container width.
struct ResizableInspectorSplit<Main: View, Inspector: View>: View {
    /// Keep the (potentially heavy) inspector subtree built. Typically "the
    /// content has an inspector" / "something is selected".
    let isMounted: Bool
    let isVisible: Bool
    /// The value the width glide is keyed on.
    let animationTrigger: AnyHashable
    let reduceMotion: Bool

    @Binding var storedWidth: Double
    /// Transient width during a drag (nil when not dragging).
    @Binding var liveWidth: Double?

    var minWidth: CGFloat = DesignTokens.Inspector.minWidth
    var maxWidth: CGFloat = DesignTokens.Inspector.maxWidth
    /// Smallest main-column slice kept visible no matter how wide the inspector is dragged — guarantees the main content never collapses under the panel or spills past the window edge.
    var mainFloor: CGFloat = 360
    /// Fired when the user drags the resize handle far enough past the panel's minimum to collapse it.
    var onClose: (() -> Void)?

    @ViewBuilder var main: () -> Main
    /// Built at the resolved full width; the container clips it to the animated
    /// visible width.
    @ViewBuilder var inspector: (CGFloat) -> Inspector

    var body: some View {
        GeometryReader { geo in
            layout(available: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func layout(available: CGFloat) -> some View {
        let fullWidth = resolvedWidth()
        let shownWidth = isVisible ? fullWidth : 0
        HStack(spacing: 0) {
            main()
                .frame(width: max(0, available - shownWidth))

            if isMounted {
                inspector(fullWidth)
                    .frame(width: shownWidth, alignment: .leading)
                    .clipped()
                    .layoutPriority(1)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .overlay(alignment: .leading) {
                        if isVisible {
                            InspectorResizeHandle(
                                width: fullWidth,
                                minWidth: minWidth,
                                maxWidth: maxWidthCap(available: available),
                                onPreviewWidthChange: { liveWidth = Double(clampLive($0, available: available)) },
                                onCommitWidth: {
                                    storedWidth = Double(clampCommit($0, available: available))
                                    liveWidth = nil
                                },
                                closeThreshold: dragToCloseEnabled ? closeArmWidth : nil,
                                onRequestClose: dragToCloseEnabled ? {
                                    liveWidth = nil
                                    onClose?()
                                } : nil
                            )
                            .offset(x: -InspectorResizeHandle.hitAreaWidth / 2)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Drag-resize must be instant, not sprung.
        .transaction(value: liveWidth) { $0.animation = nil }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0.04),
            value: animationTrigger
        )
    }

    private var dragToCloseEnabled: Bool { onClose != nil }

    /// Candidate width below which a release collapses the panel.
    private var closeArmWidth: CGFloat { max(48, minWidth - 56) }

    /// Lowest width the live drag may preview. Drag-to-close is evaluated from
    /// the handle's raw cursor travel; the rendered panel itself stops here.
    private var dragLowerBound: CGFloat { minWidth }

    /// Largest inspector width a *drag* may reach — still leaving the main column its floor at the current container width.
    private func maxWidthCap(available: CGFloat) -> CGFloat {
        let room = available - mainFloor
        return min(maxWidth, max(minWidth, room))
    }

    /// Clamp during a live drag: the rendered panel stops at its design minimum.
    /// Continuing to drag past that point arms close in `InspectorResizeHandle`.
    private func clampLive(_ candidate: CGFloat, available: CGFloat) -> CGFloat {
        min(max(candidate, dragLowerBound), maxWidthCap(available: available))
    }

    /// Clamp a committed width: always at least the design minimum, so a panel
    /// that settles (rather than closes) never persists below `minWidth`.
    private func clampCommit(_ candidate: CGFloat, available: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidthCap(available: available))
    }

    /// The rendered panel width.
    private func resolvedWidth() -> CGFloat {
        if let liveWidth {
            return min(max(CGFloat(liveWidth), minWidth), maxWidth)
        }
        return min(max(CGFloat(storedWidth), minWidth), maxWidth)
    }
}
