#if !LITE_BUILD
import SwiftUI

/// One row in either the HTML or scene project-custom-settings card.
/// Icon + title (+ optional subtitle) on the leading edge, a caller-
/// supplied control on the trailing edge.
struct WPEProjectSettingRow<Content: View>: View {
    /// Author-supplied subtitles (from `project.json`) render verbatim;
    /// app-supplied subtitles flow through the localization catalog.
    enum Subtitle {
        case authorVerbatim(String)
        case localized(LocalizedStringKey)
    }

    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: Subtitle?
    let content: Content

    init(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: Subtitle? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
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
                Text(verbatim: title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if subtitle != nil {
                    subtitleText
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

    @ViewBuilder
    private var subtitleText: some View {
        switch subtitle {
        case .authorVerbatim(let raw):
            Text(verbatim: raw)
        case .localized(let key):
            Text(key)
        case .none:
            EmptyView()
        }
    }
}

/// Renders `property.type == .group` (header) or `.text` (body copy).
/// Both are author-supplied strings already routed through the
/// `project.json` localization map at parse time.
struct WPEProjectTextBlock: View {
    let text: String
    let isHeader: Bool

    var body: some View {
        Text(verbatim: text)
            .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
            .foregroundStyle(isHeader ? .primary : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, isHeader ? 2 : 1)
    }
}

/// Inline notice rendered above the property list when a related app
/// toggle (e.g. JavaScript / Mouse Input on the HTML inspector) is off.
struct WPEProjectNotice: View {
    let icon: String
    /// App-supplied LocalizedStringKey — gate notices live in source
    /// and flow through the four bundled languages.
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
