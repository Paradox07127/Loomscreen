import AppKit
import SwiftUI

/// Segmented Liquid-Glass tabs for picking the active screen.
/// Hidden when only one display is connected. 4+ displays scroll horizontally.
struct MenuBarScreenTabs: View {
    let screens: [Screen]
    @Binding var selectedScreenIDRaw: String

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if screens.count > 1 {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let row = HStack(spacing: 6) {
            ForEach(screens, id: \.id) { screen in
                ScreenTab(
                    screen: screen,
                    isSelected: String(screen.id) == selectedScreenIDRaw,
                    summary: screenManager.wallpaperSummary(for: screen)
                ) {
                    select(screen)
                }
            }
        }

        GlassEffectContainer(spacing: 6) {
            Group {
                if screens.count >= 4 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        row.padding(.horizontal, 1)
                    }
                } else {
                    row
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Display selector"))
    }

    private func select(_ screen: Screen) {
        let target = String(screen.id)
        guard target != selectedScreenIDRaw else { return }
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.20))) {
            selectedScreenIDRaw = target
        }
    }
}

private struct ScreenTab: View {
    let screen: Screen
    let isSelected: Bool
    let summary: WallpaperSessionSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: deviceIcon)
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                Text(truncatedName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                StatusDot(activity: summary.activity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: 80, minHeight: 30)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                : .regular.interactive(),
            in: .rect(cornerRadius: DesignTokens.Corner.md)
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var deviceIcon: String {
        screen.isBuiltin ? "laptopcomputer" : "display"
    }

    private var truncatedName: String {
        let name = screen.name
        guard name.count > 10 else { return name }
        return String(name.prefix(8)) + "…"
    }

    private var accessibilityLabel: String {
        let activityWord: String
        switch summary.activity {
        case .active: activityWord = "playing"
        case .paused: activityWord = "paused"
        case .inactive: activityWord = "not configured"
        }
        return "\(screen.name), \(activityWord)"
    }
}

private struct StatusDot: View {
    let activity: WallpaperSessionActivity

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch activity {
        case .active: return .green
        case .paused: return .orange
        case .inactive: return .secondary
        }
    }
}

extension Screen {
    /// True for the integrated display (Retina laptop panel). Falls back to
    /// CGDisplayIsBuiltin when Apple's flag is reliable.
    var isBuiltin: Bool {
        CGDisplayIsBuiltin(id) != 0
    }
}
