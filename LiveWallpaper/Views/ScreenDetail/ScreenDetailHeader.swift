import SwiftUI

/// Single owner of `ScreenDetailView`'s top header zone.
///
/// Why a dedicated component: the previous design split header rendering
/// across three layers (parent toolbar gear icon, child toolbar items,
/// inline body HStack), each with its own visibility logic. Stage
/// transitions kept producing visual collisions in the transparent
/// titlebar zone. Centralising the header here means every stage
/// produces a deterministic layout, owned by one switch.
///
/// Layout: identity block (avatar + name + reload + badges) is always
/// shown — `ScreenDetailView` body's top-padding is what keeps it clear
/// of the parent toolbar's `.navigation` gear icon. Right-side actions
/// vary per stage:
/// - `chooseType`   → empty (focus is the 4-card grid below)
/// - `pickContent`  → ◀ Back
/// - `configured`   → type picker + Bookmarks + (video: Select Video /
///                    Trash) + (multi-display: Apply to All)
struct ScreenDetailHeader: View {
    var screen: Screen
    var stage: ScreenDetailView.Stage
    var wallpaperSessionSummary: WallpaperSessionSummary
    var isMultipleScreens: Bool
    var hasRuntimeError: Bool
    @Binding var selectedWallpaperType: WallpaperType
    @Binding var showBookmarks: Bool
    var refreshRateHz: Int

    let onReload: () -> Void
    let onPickVideo: () -> Void
    let onClearVideo: () -> Void
    let onBack: () -> Void
    let onApplyToAll: () -> Void

    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if case .pickContent = stage {
                backButton
            }
            identity
            Spacer()
            actions
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, 14)
    }

    /// Leading-edge Back affordance for `pickContent`. Plain chevron with
    /// `.plain` button style — macOS-idiomatic for back navigation, lighter
    /// than a `.glass` capsule so it doesn't compete with the page title.
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Return to wallpaper type selection"))
        .accessibilityLabel(Text("Back to wallpaper type selection"))
    }

    // MARK: - Identity (left of Spacer, always visible)

    private var identity: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "display").font(.system(size: 18)).foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(screen.name)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if case .configured = stage {
                        Button(action: onReload) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(Text("Reload display content"))
                        .accessibilityLabel(Text("Reload display"))
                        .accessibilityHint(Text("Reloads the wallpaper content for this screen"))
                    }
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    InfoBadge(
                        icon: "arrow.up.left.and.arrow.down.right",
                        text: "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
                    )
                    InfoBadge(icon: "gauge.medium", text: "\(refreshRateHz) Hz")
                    if case .configured = stage, wallpaperSessionSummary.isConfigured {
                        sessionStatusPill
                    }
                }
            }
        }
    }

    private var sessionStatusPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(sessionStatusColor)
                .symbolEffect(
                    .pulse,
                    options: .repeat(.continuous),
                    isActive: wallpaperSessionSummary.activity == .active
                )
            Text(sessionStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Treat the dot + text as one cohesive a11y element so VoiceOver
        // doesn't read "circle, image" before the actual status text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status: \(sessionStatusText)"))
    }

    // MARK: - Stage-aware right-side actions

    @ViewBuilder
    private var actions: some View {
        // chooseType + pickContent → no trailing actions. The Back button
        // for pickContent lives at the leading edge (see `body`).
        if case .configured = stage {
            configuredActions
        }
    }

    /// Configured-stage trailing actions, ordered left → right by
    /// scope: per-display tweaks (type / bookmarks / video re-pick / clear)
    /// → cross-display global action (Apply to All) anchored far-right so
    /// it's never confused with local controls.
    private var configuredActions: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Picker("Wallpaper Type", selection: $selectedWallpaperType) {
                ForEach(WallpaperType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(Text("Wallpaper type"))
            .accessibilityHint(Text("Switch between video, HTML, shader, or scene wallpaper"))

            Button {
                showBookmarks = true
            } label: {
                Label("Bookmarks", systemImage: "bookmark.fill")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .help(Text("Saved video / HTML / shader shortcuts"))
            .accessibilityLabel(Text("Bookmarks"))
            .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                BookmarksPopover(screen: screen)
                    .environment(screenManager)
            }

            if selectedWallpaperType == .video {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button(action: onPickVideo) {
                        Label("Select Video", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .help(Text("Choose a video file for this display"))
                    .accessibilityLabel(Text("Select video"))
                    .accessibilityHint(Text("Opens a file picker to choose a wallpaper video"))

                    Button(role: .destructive, action: onClearVideo) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .help(Text("Remove wallpaper video"))
                    .accessibilityLabel(Text("Clear video"))
                    .accessibilityHint(Text("Removes the current wallpaper video from this screen"))
                }
            }

            if isMultipleScreens {
                Button(action: onApplyToAll) {
                    Label("Apply to All", systemImage: "square.on.square")
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help(Text("Copy this display's wallpaper and settings to every other display"))
                .accessibilityLabel(Text("Apply to all displays"))
                .accessibilityHint(Text("Copies the current wallpaper and settings to every other connected display"))
                .disabled(hasRuntimeError)
            }
        }
    }

    // MARK: - Status text / color

    private var sessionStatusText: String {
        switch wallpaperSessionSummary.wallpaperType {
        case .html:        return "HTML Active"
        case .metalShader: return "Shader Active"
        case .video:       return wallpaperSessionSummary.activity == .active ? "Playing" : "Paused"
        case .scene:       return "Scene"
        case nil:          return "Not configured"
        }
    }

    private var sessionStatusColor: Color {
        switch wallpaperSessionSummary.activity {
        case .active:   return .green
        case .paused:   return .orange
        case .inactive: return .secondary
        }
    }
}
