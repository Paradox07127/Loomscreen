import LiveWallpaperCore
import SwiftUI

/// Thin wrapper so `OnboardingFlow.switch currentStep` stays uniform.
struct OnboardingStepFirstWallpaper: View {
    let policy: OnboardingPathPolicy
    let nextStep: () -> Void
    let skip: () -> Void
    let openAppleAerials: () -> Void

    var body: some View {
        OnboardingPickerView(
            galleryActions: policy.galleryActions,
            nextStep: nextStep,
            skip: skip,
            openAppleAerials: openAppleAerials
        )
    }
}
