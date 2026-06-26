import SwiftUI

/// Leading-column row number that cross-fades into a drag handle on hover/grab.
/// Not shown while playing — `EQPulseBar` takes over the leading slot then.
struct RowNumberHandle: View {
    let index: Int
    let showHandle: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else {
                Text("\(index)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .transition(.opacity)
            }
        }
        .frame(width: 18, height: 14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showHandle)
        .accessibilityHidden(true)
    }
}
