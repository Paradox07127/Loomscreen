import LiveWallpaperCore
import SwiftUI

/// Step 2 of onboarding. Thin wrapper around `OnboardingPickerView` so the
/// outer `OnboardingFlow` can own per-step state (selected display IDs) and
/// pass it down. Kept as a named step type so the flow's `switch currentStep`
/// reads consistently across all three steps.
struct OnboardingStepFirstWallpaper: View {
    let policy: OnboardingPathPolicy
    let nextStep: () -> Void
    let skip: () -> Void

    @State private var selectedScreenIDs: Set<CGDirectDisplayID> = []

    var body: some View {
        OnboardingPickerView(
            selectedScreenIDs: $selectedScreenIDs,
            galleryActions: policy.galleryActions,
            nextStep: nextStep,
            skip: skip
        )
    }
}
