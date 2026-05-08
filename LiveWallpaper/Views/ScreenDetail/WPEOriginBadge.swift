import SwiftUI

/// Glass-capsule banner on top of the Video / HTML inspector that signals
/// the active wallpaper came from a Wallpaper Engine workshop project.
/// Tapping returns the user to the Scene tab to browse / re-import.
struct WPEOriginBadge: View {
    let origin: WPEOrigin
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(.orange)
                Text("Wallpaper Engine: \(origin.title)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Wallpaper from Wallpaper Engine: \(origin.title)"))
        .accessibilityHint(Text("Tap to manage in the Scene tab"))
    }
}
