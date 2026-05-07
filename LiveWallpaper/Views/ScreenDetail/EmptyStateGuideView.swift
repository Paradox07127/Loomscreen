import SwiftUI

/// First-impression card grid shown on a display that has no saved
/// configuration. Mirrors the toolbar's segmented control 1:1 — exactly
/// four cards (Video / HTML / Shader / Scene) so users build a single
/// mental model for "wallpaper type" instead of competing
/// type-vs-source vocabularies.
///
/// Once any card is clicked the screen leaves this guide:
/// the Video card opens the file picker; the other three flip the
/// `selectedWallpaperType` and let the per-type empty state take over.
struct EmptyStateGuideView: View {
    let onChooseVideo: () -> Void
    let onChooseHTML: () -> Void
    let onChooseShader: () -> Void
    let onChooseScene: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)],
                    spacing: 16
                ) {
                    GuideCard(
                        icon: "film",
                        iconTint: .blue,
                        title: "Video",
                        subtitle: "MP4 / MOV files. Supports playlists and time-of-day schedules.",
                        actionTitle: "Pick Video…",
                        actionSystemImage: "folder",
                        action: onChooseVideo
                    )

                    GuideCard(
                        icon: "globe",
                        iconTint: .green,
                        title: "HTML",
                        subtitle: "Any web page or local HTML file. Particles and weather still apply.",
                        actionTitle: "Use HTML",
                        actionSystemImage: "arrow.right",
                        action: onChooseHTML
                    )

                    GuideCard(
                        icon: "wand.and.stars",
                        iconTint: .orange,
                        title: "Shader",
                        subtitle: "Built-in animated GPU shaders. Lightweight on the battery.",
                        actionTitle: "Use Shader",
                        actionSystemImage: "arrow.right",
                        action: onChooseShader
                    )

                    GuideCard(
                        icon: "cube.transparent",
                        iconTint: .purple,
                        title: "Scene",
                        subtitle: "Steam Workshop scenes imported from Wallpaper Engine.",
                        actionTitle: "Use Scene",
                        actionSystemImage: "arrow.right",
                        action: onChooseScene
                    )
                }
                .padding(.horizontal, 4)

                hint
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 32)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Choose a wallpaper type")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)

            Text("Each display can run a different type. You can switch from the toolbar after picking one.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
        }
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Or drag a video, HTML file, or folder anywhere on this window.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 8)
    }
}

private struct GuideCard: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String
    let actionTitle: String
    let actionSystemImage: String
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(iconTint.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(iconTint)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                Label(actionTitle, systemImage: actionSystemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(isActive ? 0.30 : 0.18))
                    )
                    .foregroundStyle(Color.accentColor)
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(minHeight: 168, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(DesignTokens.Card.strokeOpacity),
                        lineWidth: isActive ? 1.5 : DesignTokens.Card.strokeWidth
                    )
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isActive && !reduceMotion ? 1.015 : 1.0)
        .shadow(
            color: .black.opacity(isActive ? DesignTokens.Card.shadowOpacity : DesignTokens.Card.strokeOpacity),
            radius: isActive ? DesignTokens.Card.shadowRadius : 4,
            x: 0,
            y: isActive ? DesignTokens.Card.shadowYOffset : 2
        )
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.32, dampingFraction: 0.86)), value: isHovering)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.32, dampingFraction: 0.86)), value: isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title) wallpaper type")
        .accessibilityHint(subtitle)
    }
}
