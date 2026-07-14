import LiveWallpaperCore
import SwiftUI

private enum OnboardingStep: Hashable {
    case welcome
    case pick
    case workshop
    case done
}

struct OnboardingFlow: View {
    @AppStorage("Onboarding.Completed") private var hasCompletedOnboarding: Bool = false
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog

    let onClose: () -> Void
    /// AppDelegate opens the main window at the Apple Aerials library. Defaults
    /// to a no-op so previews / tests can construct the flow standalone.
    var onShowAppleAerials: () -> Void = {}

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                progressIndicator
                    .padding(.bottom, 32)
            }
        }
        .frame(width: 520, height: 540)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: index)
    }

    private var policy: OnboardingPathPolicy {
        OnboardingPathPolicy(capabilities: featureCatalog.capabilities)
    }

    private var steps: [OnboardingStep] {
        var result: [OnboardingStep] = [.welcome, .pick]
        if policy.showsWorkshopSetup { result.append(.workshop) }
        result.append(.done)
        return result
    }

    private var currentStep: OnboardingStep { steps[min(index, steps.count - 1)] }

    private var background: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.accentColor.opacity(0.28), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 200)
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch currentStep {
            case .welcome:
                OnboardingStepWelcome(nextStep: nextStep)
            case .pick:
                OnboardingPickerView(
                    galleryActions: policy.galleryActions,
                    nextStep: nextStep,
                    skip: skipToDone,
                    openAppleAerials: showAppleAerials
                )
            case .workshop:
                #if !LITE_BUILD && DIRECT_DISTRIBUTION
                OnboardingStepWorkshop(continueStep: nextStep, skip: nextStep)
                #else
                EmptyView()
                #endif
            case .done:
                OnboardingStepDone(finish: finish)
            }
        }
        .transition(stepTransition)
        .id(currentStep)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var progressIndicator: some View {
        let total = steps.count
        let stepLabel = Text("Step \(index + 1) of \(total)")
        return HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                let isCurrent = i == index
                Capsule()
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: isCurrent ? 22 : 8, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepLabel)
    }

    private func nextStep() {
        guard index < steps.count - 1 else { return }
        withAnimation { index += 1 }
    }

    private func skipToDone() {
        guard let doneIndex = steps.firstIndex(of: .done) else { return }
        withAnimation { index = doneIndex }
    }

    private func showAppleAerials() {
        hasCompletedOnboarding = true
        onShowAppleAerials()
        onClose()
    }

    private func finish() {
        hasCompletedOnboarding = true
        onClose()
    }
}
