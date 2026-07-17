import LiveWallpaperCore
import SwiftUI

/// Shared "apply to a display / apply to all" control for library tiles
/// (Bookmarks, Apple Aerials): a plain play button when there is a single
/// display, a per-display menu plus "all displays" otherwise. `tint` carries
/// the tile's accent (bookmark presentation tint vs. app accent).
struct LibraryTileApplyControl: View {
    let screens: [Screen]
    let tint: Color
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void

    var body: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { applyIcon }
            .buttonStyle(.plain)
            .help(Text("Apply"))
        } else if screens.count > 1 {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: { applyIcon }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Apply"))
        }
    }

    private var applyIcon: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(tint.opacity(0.95)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
