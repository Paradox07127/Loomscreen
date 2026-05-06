import SwiftUI

struct OnboardingStepDone: View {
    let finish: () -> Void

    private var bookmarksTip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Save favorites with Bookmarks")
                    .font(.system(size: 12, weight: .semibold))
                Text("Sidebar → Library → Bookmarks. Save any video, web page, or shader once and re-apply it later in one click.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: save favorites with Bookmarks in the sidebar")
    }

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

            Spacer().frame(height: 18)

            bookmarksTip
                .padding(.horizontal, 28)

            Spacer()

            Button(action: finish) {
                Text("Get Started")
                    .frame(minWidth: 140)
            }
            .buttonStyle(GlassCapsuleButtonStyle(fontSize: 14, horizontalPadding: 24, verticalPadding: 10))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint("Close onboarding and open LiveWallpaper")

            Spacer().frame(height: 28)
        }
    }
}
