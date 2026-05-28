#if !LITE_BUILD && DIRECT_DISTRIBUTION
import SwiftUI

/// Tiny confirmation toast presented after the user clicks "Copy
/// diagnostic" on a Workshop error state. Mirrors the visual treatment in
/// the HTML mockup (`docs/mockups/workshop-ui.html`) so the SwiftUI
/// surface keeps the same chrome users have already seen in the preview.
struct DiagnosticExportToast: View {
    @Binding var isPresented: Bool
    /// Auto-dismiss interval. Matches the mockup's 3.5 s linger so the user
    /// has time to read "Copied to clipboard" before it slides away.
    var lingerSeconds: TimeInterval = 3.5
    /// Override for previews / tests so the timer doesn't drive UI changes
    /// in a unit-test runner.
    var clock: ContinuousClock = .continuous

    var body: some View {
        Group {
            if isPresented {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.18))
                            .frame(width: 28, height: 28)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostic copied")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Paste into a GitHub issue — secrets are already redacted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
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
