import SwiftUI

/// macOS-style collapsible section with a whole-row tappable header.
struct CollapsibleSection<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.28))) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to expand")
            .accessibilityAddTraits(isExpanded ? [.isHeader, .isSelected] : .isHeader)

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
