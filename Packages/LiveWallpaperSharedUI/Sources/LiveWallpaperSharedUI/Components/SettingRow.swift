import SwiftUI

/// Inspector row pairing an icon-prefixed title with a trailing control,
/// using the native `LabeledContent` layout so spacing and alignment match
/// macOS System Settings out of the box.
///
/// `info` adds an ⓘ glyph next to the title that surfaces a per-option
/// explanation: hover triggers the system tooltip, click reveals a popover
/// with the same text. Use `info` for "what does this do" explanations and
/// keep `subtitle` for live state ("Browsing data is cleared on each
/// session") so the two roles don't bleed into each other.
public struct SettingRow<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let info: LocalizedStringKey?
    let content: Content

    public init(
        icon: String,
        iconColor: Color = .accentColor,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        info: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.info = info
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
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let info {
                        InfoTooltipButton(text: info)
                    }
                }
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

/// ⓘ glyph that exposes the same explanation through hover (system tooltip)
/// and click (popover) so the affordance is discoverable but not noisy. Public
/// so inspector rows that don't use `SettingRow` (e.g. compact slider grids)
/// can adopt the same pattern.
public struct InfoTooltipButton: View {
    let text: LocalizedStringKey
    @State private var isPresentingPopover = false

    public init(text: LocalizedStringKey) {
        self.text = text
    }

    public var body: some View {
        Button {
            isPresentingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(Text(text))
        .accessibilityLabel(Text("More information"))
        .accessibilityHint(Text(text))
        .popover(isPresented: $isPresentingPopover, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: 260, alignment: .leading)
        }
    }
}
