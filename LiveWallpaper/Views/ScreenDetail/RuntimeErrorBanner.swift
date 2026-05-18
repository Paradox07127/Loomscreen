import SwiftUI

/// Inline banner shown above the screen-detail content when the active
/// wallpaper session reports a `WallpaperRuntimeError`. Renders a title +
/// truncated path subtitle + up to two recovery actions, themed by severity
/// (error / warning / info).
struct RuntimeErrorBanner: View {
    let error: WallpaperRuntimeError
    /// `false` for backends that don't have a picker (shader / scene); the
    /// banner hides the Re-pick button so it doesn't dead-end on a no-op.
    var canRePick: Bool = true
    let onRetry: () -> Void
    let onRePick: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityTint)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: error.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                if let subtitle = error.subtitlePath, !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(error.title))
            .accessibilityValue(Text(verbatim: error.accessibilityDetail))

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
        .background(severityFill, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md))
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
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .blue
        }
    }

    private var severityFill: some ShapeStyle {
        AnyShapeStyle(.regularMaterial)
    }
}
