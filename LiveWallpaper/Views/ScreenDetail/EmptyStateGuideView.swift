import SwiftUI

/// Focal 2×2 card grid shown on a fresh display that has no saved
/// configuration. Mirrors `WallpaperType` 1:1 so users build a single
/// mental model — pick ONE of four types, the rest of the UI follows.
///
/// Compact by design: the layout fits inside the minimum window content
/// height (650pt) without scrolling, so first-time users on small windows
/// see the entire palette at a glance.
struct EmptyStateGuideView: View {
    let onChoose: (WallpaperType) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let cards: [GuideCardModel] = [
        GuideCardModel(
            type: .video,
            iconTint: .blue,
            subtitle: "MP4 / MOV with playlists and schedules.",
            actionLabel: "Pick Video…",
            actionIcon: "folder"
        ),
        GuideCardModel(
            type: .html,
            iconTint: .green,
            subtitle: "Web page or local HTML file.",
            actionLabel: "Use HTML",
            actionIcon: "arrow.right"
        ),
        GuideCardModel(
            type: .metalShader,
            iconTint: .orange,
            subtitle: "Built-in animated GPU shaders.",
            actionLabel: "Use Shader",
            actionIcon: "arrow.right"
        ),
        GuideCardModel(
            type: .scene,
            iconTint: .purple,
            subtitle: "Imported Steam Workshop scenes.",
            actionLabel: "Use Scene",
            actionIcon: "arrow.right"
        )
    ]

    var body: some View {
        VStack(spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12)],
                spacing: 12
            ) {
                ForEach(Self.cards, id: \.type) { card in
                    GuideCard(model: card) { onChoose(card.type) }
                }
            }

            hint
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Or drag a video, HTML file, or folder onto this window.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Card model

private struct GuideCardModel {
    let type: WallpaperType
    let iconTint: Color
    let subtitle: String
    let actionLabel: String
    let actionIcon: String
}

// MARK: - Card view

private struct GuideCard: View {
    let model: GuideCardModel
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(model.iconTint.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: model.type.iconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(model.iconTint)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityHidden(true)

                Text(model.type.rawValue)
                    .font(.system(size: 14, weight: .semibold))

                Text(model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Label(model.actionLabel, systemImage: model.actionIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(isActive ? 0.30 : 0.18))
                    )
                    .foregroundStyle(Color.accentColor)
            }
            .padding(DesignTokens.Spacing.md)
            .frame(minHeight: 124, alignment: .topLeading)
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
        .accessibilityLabel(Text("\(model.type.rawValue) wallpaper type"))
        .accessibilityHint(model.subtitle)
        .accessibilityAddTraits(.isButton)
    }
}
