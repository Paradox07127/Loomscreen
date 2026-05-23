import LiveWallpaperCore
import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case pick
    case done
}

struct OnboardingFlow: View {
    @AppStorage("Onboarding.Completed") private var hasCompletedOnboarding: Bool = false
    @State private var currentStep: OnboardingStep = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.featureCatalog) private var featureCatalog

    let onClose: () -> Void

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
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: currentStep)
    }

    private var policy: OnboardingPathPolicy {
        OnboardingPathPolicy(capabilities: featureCatalog.capabilities)
    }

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
                OnboardingStepFirstWallpaper(policy: policy, nextStep: nextStep, skip: skip)
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
        let totalSteps = OnboardingStep.allCases.count
        return HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { index in
                let isCurrent = index == currentStep.rawValue
                Capsule()
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: isCurrent ? 22 : 8, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentStep)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(currentStep.rawValue + 1) of \(totalSteps)"))
    }

    private func nextStep() {
        guard let next = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        withAnimation { currentStep = next }
    }

    private func skip() {
        withAnimation { currentStep = .done }
    }

    private func finish() {
        hasCompletedOnboarding = true
        onClose()
    }
}
