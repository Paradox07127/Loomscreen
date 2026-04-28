import SwiftUI

struct OnboardingStepDone: View {
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 70)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            Spacer().frame(height: 32)

            VStack(spacing: 10) {
                Text("You're All Set")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text("Open the LiveWallpaper menu bar icon any time to control playback, switch wallpapers, or change settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }

            Spacer()

            Button(action: finish) {
                Text("Get Started")
                    .frame(minWidth: 140)
            }
            .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
            .keyboardShortcut(.defaultAction)

            Spacer().frame(height: 28)
        }
    }
}
