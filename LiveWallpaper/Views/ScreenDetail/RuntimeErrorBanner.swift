import SwiftUI

/// Inline banner shown above the screen-detail content when the active
/// wallpaper session reports a `WallpaperRuntimeError`. Provides a
/// retryable hint plus a re-pick fallback for unrecoverable cases.
struct RuntimeErrorBanner: View {
    let error: WallpaperRuntimeError
    /// `false` for backends that don't have a picker (shader / scene); the
    /// banner hides the Re-pick button so it doesn't dead-end on a no-op.
    var canRePick: Bool = true
    let onRetry: () -> Void
    let onRePick: () -> Void

    private var subtitleText: String {
        switch (error.canRetry, canRePick) {
        case (true, true):
            return "Tap Retry to try again or Re-pick to choose another source."
        case (true, false):
            return "Tap Retry to try again."
        case (false, true):
            return "Tap Re-pick to choose another source."
        case (false, false):
            return "Switch to a different wallpaper type to recover."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(error.userMessage)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if error.canRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityHint("Retry loading the current wallpaper source")
            }
            if canRePick {
                Button("Re-pick", action: onRePick)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Pick a different wallpaper source")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.orange.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
