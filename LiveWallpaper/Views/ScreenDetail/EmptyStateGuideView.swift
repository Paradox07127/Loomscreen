import SwiftUI

/// First-impression card grid shown when a display has no saved
/// configuration. Replaces the old per-type empty states (which only made
/// sense after the user had picked a wallpaper type) with a clear menu of
/// the four primary content sources.
///
/// Each card is a fully tabbable button — keyboard navigation cycles
/// through them, and each carries an explicit accessibility label so
/// VoiceOver reads "Apple Aerials, downloads-curated landscapes" etc.
struct EmptyStateGuideView: View {
    let onUseAerials: () -> Void
    let onPickVideo: () -> Void
    let onAddWebURL: () -> Void
    let onImportWallpaperEngine: () -> Void
    /// Drives the optional 4th card. Hidden when the user has neither a
    /// detected Steam library nor a manually-rooted Workshop folder, so we
    /// don't dangle a dead-end CTA in front of new users.
    let supportsWallpaperEngineImport: Bool

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
                        icon: "sparkles.tv",
                        iconTint: .orange,
                        title: "Apple Aerials",
                        subtitle: "Curated nature landscapes already on your Mac.",
                        actionTitle: "Try Now",
                        actionSystemImage: "play.fill",
                        action: onUseAerials
                    )

                    GuideCard(
                        icon: "film",
                        iconTint: .blue,
                        title: "Pick Video",
                        subtitle: "Use any MP4 / MOV file from your library.",
                        actionTitle: "Browse…",
                        actionSystemImage: "folder",
                        action: onPickVideo
                    )

                    GuideCard(
                        icon: "globe",
                        iconTint: .green,
                        title: "Web URL",
                        subtitle: "Show any web page or local HTML as a live wallpaper.",
                        actionTitle: "Add URL…",
                        actionSystemImage: "link",
                        action: onAddWebURL
                    )

                    if supportsWallpaperEngineImport {
                        GuideCard(
                            icon: "cube.transparent",
                            iconTint: .purple,
                            title: "Wallpaper Engine",
                            subtitle: "Import a Steam Workshop scene from your library.",
                            actionTitle: "Import…",
                            actionSystemImage: "tray.and.arrow.down",
                            action: onImportWallpaperEngine
                        )
                    }
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

            Text("Pick a wallpaper to get started")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)

            Text("Each display can use a different content source. You can change this later from this same screen.")
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
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
