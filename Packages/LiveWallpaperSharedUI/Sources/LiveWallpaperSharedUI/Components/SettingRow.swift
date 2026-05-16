import SwiftUI

/// Inspector row pairing an icon-prefixed title with a trailing control,
/// using the native `LabeledContent` layout so spacing and alignment match
/// macOS System Settings out of the box.
public struct SettingRow<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let content: Content

    public init(
        icon: String,
        iconColor: Color = .accentColor,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            content
        }
        .controlSize(.small)
        .padding(.vertical, 3)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }
}
