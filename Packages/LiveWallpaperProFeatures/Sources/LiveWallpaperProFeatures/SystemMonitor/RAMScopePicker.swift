import LiveWallpaperSharedUI
import SwiftUI

public struct RAMScopePicker: View {
    @Binding var selection: String
    public var maxWidth: CGFloat?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: Binding<String>, maxWidth: CGFloat? = nil) {
        self._selection = selection
        self.maxWidth = maxWidth
    }

    public var body: some View {
        HStack(spacing: 0) {
            scopeButton(label: "All", value: "system")
            scopeButton(label: "App", value: "app")
        }
        .padding(2)
        .background(Capsule().fill(Color.gray.opacity(0.18)))
        .frame(maxWidth: maxWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("RAM scope"))
    }

    @ViewBuilder
    private func scopeButton(label: LocalizedStringKey, value: String) -> some View {
        Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) {
                selection = value
            }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selection == value ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(selection == value ? Color.accentColor.opacity(0.35) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == "system"
            ? Text("Show whole-system memory usage", comment: "RAM scope toggle a11y label when scope is the whole system.")
            : Text("Show this app's memory usage", comment: "RAM scope toggle a11y label when scope is the LiveWallpaper app only."))
    }
}
