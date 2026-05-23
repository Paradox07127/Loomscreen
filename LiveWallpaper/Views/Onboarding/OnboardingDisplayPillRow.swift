import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Inline pill-rail display selector for onboarding. Only renders when more
/// than one display is connected — single-display setups would just see a
/// noisy "Apply to: MacBook" with no target choice.
///
/// Reconciles `selectedScreenIDs` against `screens` on appear and on screen-list
/// changes so unplugging a monitor mid-onboarding can't leave the user with
/// an empty target set (the Apply CTA would deadlock).
struct OnboardingDisplayPillRow: View {
    let screens: [Screen]
    @Binding var selectedScreenIDs: Set<CGDirectDisplayID>

    var body: some View {
        Group {
            if screens.count > 1 {
                HStack(spacing: 10) {
                    Text("Apply to:", comment: "Label preceding the onboarding display-selector pill rail.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(screens) { screen in
                                pill(for: screen)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: screens.map(\.id)) { _, _ in reconcileSelection() }
    }

    @ViewBuilder
    private func pill(for screen: Screen) -> some View {
        let isSelected = selectedScreenIDs.contains(screen.id)
        Button {
            toggle(screen.id)
        } label: {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(verbatim: screen.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                }
            }
            .modifier(UnselectedPillSurface(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(Text("\(screen.name) display"))
        .accessibilityValue(isSelected
            ? Text("Selected", comment: "A11y value for the onboarding display pill when the display is selected.")
            : Text("Not selected", comment: "A11y value for the onboarding display pill when the display is unselected."))
        .accessibilityHint(Text(
            "Toggles whether the wallpaper applies to this display",
            comment: "A11y hint for the onboarding display selector pill."
        ))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(_ id: CGDirectDisplayID) {
        if selectedScreenIDs.contains(id) {
            guard selectedScreenIDs.count > 1 else { return }
            selectedScreenIDs.remove(id)
        } else {
            selectedScreenIDs.insert(id)
        }
    }

    private func reconcileSelection() {
        let valid = Set(screens.map(\.id))
        guard !valid.isEmpty else {
            selectedScreenIDs = []
            return
        }
        let intersection = selectedScreenIDs.intersection(valid)
        selectedScreenIDs = intersection.isEmpty ? valid : intersection
    }
}

/// Glass-capsule chrome for the unselected pill state. Extracted so the
/// selected state can opt out without conditionally returning a different
/// outer view (which would break SwiftUI identity for keyboard focus).
private struct UnselectedPillSurface: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
        } else {
            content.adaptiveGlassSurface(.capsule, interactive: true)
        }
    }
}
