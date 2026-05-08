import SwiftUI

/// Hero card for the currently selected screen: a 16:9 placeholder, the
/// wallpaper title, and the floating transport capsule.
struct MenuBarHeroSection: View {
    let screen: Screen
    let openSettingsForScreen: (CGDirectDisplayID) -> Void

    @Environment(ScreenManager.self) private var screenManager
    @State private var trustStore = TrustedHostStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            heroCard
            titleRow
            untrustedHostBanner
        }
    }

    // MARK: - Hero card

    private var heroCard: some View {
        ZStack(alignment: .bottom) {
            heroBackground
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))

            MenuBarTransportCapsule(screen: screen)
                .padding(.bottom, DesignTokens.Spacing.sm)
        }
    }

    @ViewBuilder
    private var heroBackground: some View {
        let summary = screenManager.wallpaperSummary(for: screen)
        let baseColor = baseColor(for: summary.wallpaperType)
        LinearGradient(
            colors: [baseColor.opacity(0.55), baseColor.opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .center) {
            if !summary.isConfigured {
                VStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Not configured")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(screen.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(nowPlayingLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                openSettingsForScreen(screen.id)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Configure this display")
            .accessibilityLabel("Open settings for \(screen.name)")
        }
    }

    // MARK: - Trust banner

    @ViewBuilder
    private var untrustedHostBanner: some View {
        if case let .untrustedRemote(host) = trustVerdict() {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.orange)
                Text("JavaScript disabled for \(host)")
                    .font(.system(size: 11))
                Spacer(minLength: 0)
                Button("Trust") {
                    if trustStore.trust(host) {
                        screenManager.reloadWallpaperForScreen(screen)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.mini)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .glassEffect(
                .regular.tint(Color.orange.opacity(0.25)).interactive(),
                in: .rect(cornerRadius: DesignTokens.Corner.md)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("JavaScript disabled for \(host). Tap Trust to allow.")
        }
    }

    // MARK: - Helpers

    private func trustVerdict() -> HTMLTrust {
        guard let source = screenManager.getConfiguration(for: screen)?.htmlSource else {
            return .localContent
        }
        return HTMLTrust.evaluate(source: source, trustedHosts: trustStore.hostSet)
    }

    private var iconName: String {
        let summary = screenManager.wallpaperSummary(for: screen)
        switch summary.wallpaperType {
        case .html: return "globe"
        case .metalShader: return "sparkles.rectangle.stack"
        case .video: return summary.activity == .active ? "play.rectangle.fill" : "pause.rectangle.fill"
        case .scene: return "cube.transparent"
        case nil: return "display"
        }
    }

    private var nowPlayingLabel: String {
        guard let cfg = screenManager.getConfiguration(for: screen) else { return "Not configured" }
        switch cfg.activeWallpaper {
        case .video:
            let cursor = cfg.playlistCursorIndex ?? 0
            let combined = [cfg.savedVideoBookmarkData].compactMap { $0 } + (cfg.playlistBookmarks ?? [])
            if cursor < combined.count, let name = ResourceUtilities.resolveBookmarkName(combined[cursor]) {
                return name
            }
            return "Video"
        case .html(let source, _):
            return source.displayName
        case .metalShader(let preset):
            return preset.rawValue
        case .scene:
            return "Scene wallpaper"
        }
    }

    private func baseColor(for type: WallpaperType?) -> Color {
        switch type {
        case .video: return .blue
        case .html: return .green
        case .metalShader: return .purple
        case .scene: return .orange
        case nil: return .gray
        }
    }
}
