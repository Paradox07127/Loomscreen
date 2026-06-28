#if !LITE_BUILD && DIRECT_DISTRIBUTION
import LiveWallpaperSharedUI
import SwiftUI

/// First-time-only sheet shown before the paste sheet opens. Mirrors the
/// onboarding mockup (`docs/mockups/workshop-ui.html`).
struct WorkshopOnboardingSheet: View {
    @AppStorage("loomscreen.workshop.onboarding.shown.v1") private var hasShown: Bool = false
    @Environment(\.dismiss) private var dismiss
    /// Called on finish so the caller can open the paste sheet immediately.
    var onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            illustration
            VStack(spacing: 8) {
                Text("Browse Wallpaper Engine from Steam")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Paste a Workshop URL to preview it, or set up online browsing and downloading.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                bullet(systemImage: "network", text: "Direct to Valve over HTTPS — no third-party services.")
                bullet(systemImage: "key", text: "Online browsing uses your own free Steam Web API key.")
                bullet(systemImage: "arrow.down.circle", text: "Downloads run through Steam's official SteamCMD.")
            }
            .frame(maxWidth: 420, alignment: .leading)

            Spacer(minLength: 6)

            VStack(spacing: 8) {
                Button {
                    hasShown = true
                    dismiss()
                    onGetStarted()
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: 220)
                        .padding(.vertical, 4)
                }
                .keyboardShortcut(.defaultAction)

                Button("Maybe later") { dismiss() }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 26)
        .frame(width: 480)
        .background(DesignTokens.Colors.pageBackground)
    }

    private func bullet(systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(verbatim: text)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var illustration: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 100, height: 100)
            Image(systemName: "cube.transparent")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }
}
#endif
