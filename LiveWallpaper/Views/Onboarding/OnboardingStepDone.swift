import LiveWallpaperCore
import SwiftUI

struct OnboardingStepDone: View {
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)

            Spacer().frame(height: 20)

            VStack(spacing: 10) {
                Text("You're All Set")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)

                Text("Open the LiveWallpaper menu bar icon at any time to control playback, switch wallpapers, or change settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            Spacer().frame(height: 18)

            nextStepsCard
                .padding(.horizontal, 28)

            Spacer()

            Button(action: finish) {
                Text("Get Started")
                    .frame(minWidth: 140)
            }
            .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Close onboarding and open LiveWallpaper"))

            Spacer().frame(height: 28)
        }
    }

    private var nextStepsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next steps", comment: "Header label for the onboarding completion tip list.")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            ForEach(Array(tipBullets.enumerated()), id: \.offset) { _, tip in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: tip.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16, alignment: .center)
                        .accessibilityHidden(true)
                    Text(tip.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }

    private let tipBullets: [DoneStepTip] = [
        .init(symbol: "calendar.badge.clock", text: "Set up playlists or schedule changes"),
        .init(symbol: "sparkles", text: "Tweak speed, fit, color, and effects"),
        .init(symbol: "bookmark.fill", text: "Save favorites with Bookmarks"),
        .init(symbol: "play.tv", text: "Browse Apple Aerials from the sidebar")
    ]
}

private struct DoneStepTip {
    let symbol: String
    let text: LocalizedStringKey
}
