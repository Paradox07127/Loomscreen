import SwiftUI

/// Compact "DEV" badge shown next to sidebar items that are surfaced
/// only when the user has opted into Developer Mode. The pill stays
/// quiet — orange tinted capsule with a thin border — so it reads as an
/// opt-in marker, not a destructive warning. Pure SwiftUI shapes; does
/// not route through `AdaptiveGlass` (a glass material would over-weight
/// a 9pt badge inside a NavigationLink row).
public struct DevPill: View {
    public init() {}

    public var body: some View {
        Text(verbatim: "DEV")
            .font(DesignTokens.Typography.badge)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .tracking(0.4)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(Color.orange)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.15))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
            )
            .accessibilityLabel(Text("Developer mode active"))
    }
}
