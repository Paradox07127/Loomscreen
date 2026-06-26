import LiveWallpaperCore
import SwiftUI

/// Wrapper around `OnboardingPickerView` owning per-step state (selected
/// display IDs); a named step type so `OnboardingFlow.switch currentStep` is uniform.
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
