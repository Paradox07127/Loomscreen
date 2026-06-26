import SwiftUI

/// Mirrors the video panel's Single / Playlist / Schedule pill control so the
/// screen-detail surface stays visually consistent.
struct HTMLSourceKindPicker: View {
    @Binding var selection: HTMLSourceKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HTMLSourceKind.allCases) { kind in
                Button {
                    let animation = DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))
                    withAnimation(animation) {
                        selection = kind
                    }
                } label: {
                    Text(kind.labelKey)
                        .font(selection == kind ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(selection == kind ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(kind.labelKey))
            }
        }
        .padding(2)
        .adaptiveGlassSurface(.capsule, interactive: true)
    }
}
