import SwiftUI

struct LibraryGuideFeature: Equatable {
    let icon: String
    let text: String
}

struct LibraryGuideCard: View {
    let icon: String
    let title: String
    let message: String
    let features: [LibraryGuideFeature]
    let actionTitle: String
    let actionSystemImage: String
    let secondaryTitle: String?
    let secondarySystemImage: String?
    let isActionInProgress: Bool
    let errorMessage: String?
    let action: () -> Void
    let secondaryAction: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String,
        features: [LibraryGuideFeature],
        actionTitle: String,
        actionSystemImage: String,
        secondaryTitle: String? = nil,
        secondarySystemImage: String? = nil,
        isActionInProgress: Bool = false,
        errorMessage: String? = nil,
        action: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.features = features
        self.actionTitle = actionTitle
        self.actionSystemImage = actionSystemImage
        self.secondaryTitle = secondaryTitle
        self.secondarySystemImage = secondarySystemImage
        self.isActionInProgress = isActionInProgress
        self.errorMessage = errorMessage
        self.action = action
        self.secondaryAction = secondaryAction
    }

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 24)

            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(features, id: \.text) { feature in
                    featureRow(feature)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    .blendMode(.overlay)
            )
            .frame(maxWidth: 380)

            HStack(spacing: 10) {
                Button(action: action) {
                    HStack(spacing: 8) {
                        if isActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label(actionTitle, systemImage: actionSystemImage)
                            .frame(minWidth: 132)
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 13, horizontalPadding: 22, verticalPadding: 9))
                .disabled(isActionInProgress)
                .keyboardShortcut(.defaultAction)

                if let secondaryTitle, let secondaryAction {
                    Button(action: secondaryAction) {
                        if let secondarySystemImage {
                            Label(secondaryTitle, systemImage: secondarySystemImage)
                                .frame(minWidth: 96)
                        } else {
                            Text(secondaryTitle)
                                .frame(minWidth: 96)
                        }
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(tint: .secondary, fontSize: 13, horizontalPadding: 18, verticalPadding: 9))
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func featureRow(_ feature: LibraryGuideFeature) -> some View {
        HStack(spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .symbolRenderingMode(.hierarchical)

            Text(feature.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}
