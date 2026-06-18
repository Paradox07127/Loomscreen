import LiveWallpaperSharedUI
import SwiftUI

/// A detail layout that pairs a main column with a full-height inspector panel
/// on the trailing edge, resolving widths against the live container width.
///
/// This is the shared mechanism behind the screen-detail properties panel and
/// the Workshop detail panels. Showing/hiding or resizing the inspector only
/// redistributes the detail's own width, so it never pushes a larger minimum
/// onto a surrounding split view — which is what used to steal width from the
/// sidebar and overflow the toolbar into `»`.
///
/// Two details keep the reveal smooth:
/// - The inspector subtree stays **mounted** while `isMounted`, so toggling
///   animates a single width value instead of rebuilding the subtree on the
///   first animated frame (the old expand stutter).
/// - The glide is driven by a view-level `.animation(value:)`, which
///   interpolates wherever the toggle is fired — including from a separately
///   hosted `NSToolbar` button, where a `withAnimation` transaction wouldn't
///   reach this content.
struct ResizableInspectorSplit<Main: View, Inspector: View>: View {
    /// Keep the (potentially heavy) inspector subtree built. Typically "the
    /// content has an inspector" / "something is selected".
    let isMounted: Bool
    /// Whether the inspector is currently revealed (animates width 0 ↔ full).
    let isVisible: Bool
    /// The value the width glide is keyed on. Pass the *user-intent* flag
    /// (toggle / selection), NOT `isVisible`, so programmatic mount changes
    /// (e.g. switching content type) stay instant.
    let animationTrigger: AnyHashable
    let reduceMotion: Bool

    /// Persisted inspector width.
    @Binding var storedWidth: Double
    /// Transient width during a drag (nil when not dragging).
    @Binding var liveWidth: Double?

    var minWidth: CGFloat = DesignTokens.Inspector.minWidth
    var maxWidth: CGFloat = DesignTokens.Inspector.maxWidth
    /// Smallest main-column slice kept visible no matter how wide the inspector
    /// is dragged — guarantees the main content never collapses under the panel
    /// or spills past the window edge.
    var mainFloor: CGFloat = 360
    /// Fired when the user drags the resize handle far enough past the panel's
    /// minimum to collapse it. When nil, drag-to-close is off and the handle is
    /// a pure resizer clamped at `minWidth`.
    var onClose: (() -> Void)? = nil

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
                    // The panel wins any layout contention, so opening the left
                    // sidebar (or anything else that narrows the detail column)
                    // compresses the MAIN column, never the panel. Both edges
                    // stay put; only the middle gives.
                    .layoutPriority(1)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .overlay(alignment: .leading) {
                        if isVisible {
                            InspectorResizeHandle(
                                width: fullWidth,
                                minWidth: dragLowerBound,
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
        // Glide the width only when the user intent changes (toggle / select).
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0.04),
            value: animationTrigger
        )
    }

    private var dragToCloseEnabled: Bool { onClose != nil }

    /// Candidate width below which a release collapses the panel. Sits a fixed
    /// over-drag past the minimum so a deliberate yank — not an ordinary
    /// narrow-down — is what closes it.
    private var closeArmWidth: CGFloat { max(48, minWidth - 56) }

    /// Lowest width the live drag may preview. With drag-to-close on, the panel
    /// can shrink into a thin sliver to telegraph the collapse; otherwise it
    /// stops at the design minimum.
    private var dragLowerBound: CGFloat {
        dragToCloseEnabled ? min(closeArmWidth - 12, 60) : minWidth
    }

    /// Largest inspector width a *drag* may reach — still leaving the main
    /// column its floor at the current container width. Only the resize handle
    /// uses this; the rendered width below ignores `available` on purpose.
    private func maxWidthCap(available: CGFloat) -> CGFloat {
        let room = available - mainFloor
        return min(maxWidth, max(minWidth, room))
    }

    /// Clamp during a live drag: lower bound is `dragLowerBound` (a sliver when
    /// drag-to-close is on) so the panel can visibly narrow past its minimum.
    private func clampLive(_ candidate: CGFloat, available: CGFloat) -> CGFloat {
        min(max(candidate, dragLowerBound), maxWidthCap(available: available))
    }

    /// Clamp a committed width: always at least the design minimum, so a panel
    /// that settles (rather than closes) never persists below `minWidth`.
    private func clampCommit(_ candidate: CGFloat, available: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidthCap(available: available))
    }

    /// The rendered panel width. Clamped to the design min/max ONLY — never to
    /// `available` — so opening/closing the left sidebar (which changes the
    /// detail column width) leaves the panel untouched and lets the main column
    /// absorb the change. `maxWidth` is small enough that even at the minimum
    /// window the main column keeps ample room, so this never overflows.
    ///
    /// During a live drag the lower bound drops to `dragLowerBound` so the panel
    /// follows the cursor into the sliver zone while dragging to close.
    private func resolvedWidth() -> CGFloat {
        if let liveWidth {
            return min(max(CGFloat(liveWidth), dragLowerBound), maxWidth)
        }
        return min(max(CGFloat(storedWidth), minWidth), maxWidth)
    }
}
