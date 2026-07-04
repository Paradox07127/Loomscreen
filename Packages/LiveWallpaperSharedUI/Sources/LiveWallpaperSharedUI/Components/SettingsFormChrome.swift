import SwiftUI
import AppKit

extension View {
    public func settingsFormChrome(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) -> some View {
        modifier(SettingsFormChrome(minWidth: minWidth, minHeight: minHeight))
    }
}

private struct SettingsFormChrome: ViewModifier {
    let minWidth: CGFloat?
    let minHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, DesignTokens.Settings.formHorizontalMargin, for: .scrollContent)
            .contentMargins(.vertical, DesignTokens.Settings.formVerticalMargin, for: .scrollContent)
            .background(DesignTokens.Colors.pageBackground)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .settingsStickySectionChrome()
    }
}
