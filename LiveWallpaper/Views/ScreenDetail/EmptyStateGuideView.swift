import LiveWallpaperCore
import SwiftUI

/// Card grid for a display with no saved configuration. Shader/Scene cards
/// are gated by `featureCatalog` so Lite users see only types their SKU can
/// render. Video opens the file picker; the others flip `selectedWallpaperType`.
struct EmptyStateGuideView: View {
    let onChooseVideo: () -> Void
    let onChooseHTML: () -> Void
    let onChooseShader: () -> Void
    let onChooseScene: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 14)],
                    spacing: 12
                ) {
                    GuideCard(
                        icon: "film",
                        iconTint: .blue,
                        title: "Video",
                        subtitle: videoSubtitle,
                        accessibilityLabel: "Video wallpaper type",
                        action: onChooseVideo
                    )

                    GuideCard(
                        icon: "globe",
                        iconTint: .green,
                        title: "Web",
                        subtitle: "Web pages, local .html files, and folders.",
                        accessibilityLabel: "Web wallpaper type",
                        action: onChooseHTML
                    )

                    if featureCatalog.isEnabled(.metalShader) {
                        GuideCard(
                            icon: "wand.and.stars",
                            iconTint: .orange,
                            title: "Shader",
                            subtitle: "Built-in animated GPU shaders.",
                            accessibilityLabel: "Shader wallpaper type",
                            action: onChooseShader
                        )
                    }

                    if featureCatalog.isEnabled(.scene) {
                        GuideCard(
                            icon: "cube.transparent",
                            iconTint: .purple,
                            title: "Scene",
                            subtitle: "Compatible imported scenes.",
                            accessibilityLabel: "Scene wallpaper type",
                            action: onChooseScene
                        )
                    }
                }
                .padding(.horizontal, 4)

                hint
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoSubtitle: LocalizedStringKey {
        featureCatalog.isEnabled(.playlists) || featureCatalog.isEnabled(.scheduleAutomation)
            ? "MP4 / MOV, playlists, and schedules."
            : "MP4 / MOV from your Mac."
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Choose a wallpaper type")
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)

            Text("Pick a type for this display. You can switch later.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
        }
    }

    private var hint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
            Text("Or drag a video, web file, or folder here.")
                .font(DesignTokens.Typography.caption)
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .padding(.top, 6)
    }
}

private struct GuideCard: View {
    let icon: String
    let iconTint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .fill(iconTint.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(iconTint)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text(title)
                        .font(DesignTokens.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(minHeight: 128, alignment: .center)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
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
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(subtitle))
    }
}
