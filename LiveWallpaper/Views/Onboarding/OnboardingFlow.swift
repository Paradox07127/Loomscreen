import SwiftUI

struct OnboardingFlow: View {
    @AppStorage("Onboarding.Completed") private var hasCompletedOnboarding: Bool = false
    @State private var currentStep: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .frame(width: 520, height: 580)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: currentStep)
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
            case 0:
                OnboardingStepWelcome(nextStep: nextStep)
            case 1:
                OnboardingStepFirstWallpaper(nextStep: nextStep, skip: skip)
            default:
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
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Capsule()
                    .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: index == currentStep ? 22 : 8, height: 6)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentStep)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(currentStep + 1) of 3"))
    }

    private func nextStep() {
        guard currentStep < 2 else { return }
        withAnimation { currentStep += 1 }
    }

    private func skip() {
        withAnimation { currentStep = 2 }
    }

    private func finish() {
        hasCompletedOnboarding = true
        onClose()
    }
}
