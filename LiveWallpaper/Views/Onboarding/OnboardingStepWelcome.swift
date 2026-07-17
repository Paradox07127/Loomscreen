import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

struct OnboardingStepWelcome: View {
    let nextStep: () -> Void
    @Environment(\.featureCatalog) private var featureCatalog

    private var tagline: LocalizedStringKey {
        featureCatalog.isEnabled(.scene)
            ? "Video, web, shaders, and Wallpaper Engine scenes — alive on every display."
            : "Local video, interactive web, and Apple Aerials — alive on every display."
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 36)

            appIcon
                .frame(width: 120, height: 120)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

            Spacer().frame(height: 26)

            VStack(spacing: 10) {
                Text("Welcome to LiveWallpaper")
                    .font(DesignTokens.Typography.hero)
                    .accessibilityAddTraits(.isHeader)

                Text(tagline)
                    .font(DesignTokens.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()

            Button(action: nextStep) {
                Text("Continue")
                    .frame(minWidth: 140)
            }
            .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Proceed to choose your first wallpaper"))

            Spacer().frame(height: 28)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSImage(named: "AppIcon") {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "play.rectangle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor)
        }
    }
}
