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
    let title: Text
    let subtitle: Text?
    let info: Text?
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
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.info = info.map { Text($0) }
        self.content = content()
    }

    /// Verbatim variant for already-resolved runtime/author strings (e.g. a
    /// Wallpaper Engine property display name) that must NOT be re-looked-up in
    /// the localization catalog. Distinct `verbatim*` labels avoid overload
    /// ambiguity with the `LocalizedStringKey` initializer at string-literal
    /// call sites.
    public init(
        icon: String,
        iconColor: Color = .accentColor,
        verbatimTitle: String,
        verbatimSubtitle: String? = nil,
        info: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = Text(verbatim: verbatimTitle)
        self.subtitle = verbatimSubtitle.map { Text(verbatim: $0) }
        self.info = info.map { Text($0) }
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(iconColor)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    title
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let info {
                        InfoTooltipButton(text: info)
                    }
                }
                if let subtitle = subtitle {
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

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
    let text: Text
    @State private var isPresentingPopover = false

    public init(text: LocalizedStringKey) {
        self.text = Text(text)
    }

    public init(verbatim text: String) {
        self.text = Text(verbatim: text)
    }

    fileprivate init(text: Text) {
        self.text = text
    }

    public var body: some View {
        Button {
            isPresentingPopover.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(Text("More information"))
        .accessibilityHint(text)
        .popover(isPresented: $isPresentingPopover, arrowEdge: .top) {
            text
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
    }
}
