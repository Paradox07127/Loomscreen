#if !LITE_BUILD
import LiveWallpaperSharedUI
import SwiftUI

/// Confirmation toast after "Copy diagnostic" on a Workshop error state.
/// Mirrors the chrome in the HTML mockup (`docs/mockups/workshop-ui.html`).
struct DiagnosticExportToast: View {
    @Binding var isPresented: Bool
    /// Matches the mockup's 3.5 s linger — long enough to read before it slides away.
    var lingerSeconds: TimeInterval = 3.5
    /// Overridable so the auto-dismiss timer doesn't drive UI in a test runner.
    var clock: ContinuousClock = .continuous

    var body: some View {
        Group {
            if isPresented {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(DesignTokens.Colors.Status.active.opacity(0.18))
                            .frame(width: 28, height: 28)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DesignTokens.Colors.Status.active)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostic copied")
                            .font(DesignTokens.Typography.bodyEmphasized)
                        Text("Paste into a GitHub issue — secrets are already redacted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .adaptiveGlassSurface(.capsule)
                .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: isPresented) {
                    guard isPresented else { return }
                    try? await clock.sleep(for: .milliseconds(Int(lingerSeconds * 1_000)))
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text("Diagnostic copied to clipboard. Secrets are already redacted."))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresented)
    }
}
#endif
