import LiveWallpaperCore
import SwiftUI

struct GeneralSettingsStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(DesignTokens.Typography.captionEmphasized)
            .foregroundStyle(color)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xxs)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.24), lineWidth: 0.5))
            .fixedSize()
    }
}
