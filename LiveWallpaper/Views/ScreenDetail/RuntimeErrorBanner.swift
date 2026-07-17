import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Inline banner shown above the screen-detail content when the active
/// wallpaper session reports a `WallpaperRuntimeError`.
struct RuntimeErrorBanner: View {
    let error: WallpaperRuntimeError
    /// `false` for wallpaper types without a picker (shader / scene); the
    /// banner hides the Re-pick button so it doesn't dead-end on a no-op.
    var canRePick: Bool = true
    let onRetry: () -> Void
    let onRePick: () -> Void

    var body: some View {
        let sanitizedTitle = PIISanitizer.scrub(error.title)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityTint)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: sanitizedTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let subtitle = error.subtitlePath, !subtitle.isEmpty {
                    Text(verbatim: PIISanitizer.scrub(subtitle))
                        .font(DesignTokens.Typography.codeCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: sanitizedTitle))
            .accessibilityValue(Text(verbatim: PIISanitizer.scrub(error.accessibilityDetail)))

            Spacer(minLength: 8)

            if error.canRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint(Text("Retry loading the current wallpaper source"))
            }
            if canRePick {
                Button("Re-pick", action: onRePick)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(Text("Pick a different wallpaper source"))
            }
        }
        .padding(12)
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), tint: severityTint)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                .stroke(severityTint.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var severityIcon: String {
        switch error.severity {
        case .error:   return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private var severityTint: Color {
        switch error.severity {
        case .error:   return DesignTokens.Colors.Status.danger
        case .warning: return DesignTokens.Colors.Status.warning
        case .info:    return .blue
        }
    }
}
