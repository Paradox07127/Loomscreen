import SwiftUI

/// Collapsible section with a tappable header. The `trailingAccessory` slot (e.g. a
/// Reset button) is kept outside the expand `Button` so its taps don't fight collapse/expand.
public struct CollapsibleSection<Content: View, TrailingAccessory: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var trailingAccessory: () -> TrailingAccessory
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: LocalizedStringKey,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailingAccessory: @escaping () -> TrailingAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self._isExpanded = isExpanded
        self.trailingAccessory = trailingAccessory
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.28))) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label(title, systemImage: systemImage)
                            .font(DesignTokens.Typography.sectionTitle)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityHint(isExpanded
                    ? Text("Tap to collapse", comment: "A11y hint for an expanded collapsible section header.")
                    : Text("Tap to expand", comment: "A11y hint for a collapsed section header."))
                .accessibilityAddTraits(isExpanded ? [.isHeader, .isSelected] : .isHeader)

                trailingAccessory()

                Button {
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.28))) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityHidden(true)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    content()
                }
                .padding(.top, 10)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    )
                )
            }
        }
    }
}

extension CollapsibleSection where TrailingAccessory == EmptyView {
    public init(
        title: LocalizedStringKey,
        systemImage: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            isExpanded: isExpanded,
            trailingAccessory: { EmptyView() },
            content: content
        )
    }
}
