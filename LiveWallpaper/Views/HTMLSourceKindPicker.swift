import SwiftUI

/// Pill-style segmented picker that mirrors the Single / Playlist / Schedule
/// control on the video panel, so the HTML source kind switcher shares the
/// same visual rhythm with the rest of the screen-detail surface.
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
                        .font(.system(size: 12, weight: selection == kind ? .semibold : .regular))
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
