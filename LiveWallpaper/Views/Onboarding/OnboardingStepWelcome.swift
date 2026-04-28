import SwiftUI

struct OnboardingStepWelcome: View {
    let nextStep: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 60)

            appIcon
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

            Spacer().frame(height: 32)

            VStack(spacing: 10) {
                Text("Welcome to LiveWallpaper")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text("Bring your desktop to life with stunning dynamic wallpapers across every display.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }

            Spacer()

            Button(action: nextStep) {
                Text("Continue")
                    .frame(minWidth: 140)
            }
            .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Proceed to choose your first wallpaper")

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
