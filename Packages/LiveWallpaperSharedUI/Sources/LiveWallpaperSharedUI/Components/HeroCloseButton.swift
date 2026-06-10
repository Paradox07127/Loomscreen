import SwiftUI

/// Floating "collapse the detail inspector" control, designed to overlay the
/// top-leading corner of a hero/preview image. A sidebar glyph that rests light
/// (still legible over bright previews) and firms up to a solid button on hover.
///
/// Owns its own hover state, so call sites only pass a close action. Per-element
/// opacity (never a blanket `.opacity` on the button) keeps contrast acceptable
/// over both bright and dark artwork. Binds `Esc` (`.cancelAction`) so keyboard
/// users can dismiss without reaching for the glyph.
public struct HeroCloseButton: View {
    private let action: () -> Void
    @State private var hovered = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
                .frame(width: 28, height: 28)
                .floatingGlyphGlass(hovered: hovered)
                .overlay(Circle().strokeBorder(.white.opacity(hovered ? 0.35 : 0.2), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut(.cancelAction)
        .help(Text("Hide details (Esc)"))
        .accessibilityLabel(Text("Hide details"))
    }
}
