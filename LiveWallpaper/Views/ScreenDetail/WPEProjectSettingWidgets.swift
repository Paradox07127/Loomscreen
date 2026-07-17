#if !LITE_BUILD
import LiveWallpaperSharedUI
import SwiftUI

struct WPEProjectSettingRow<Content: View>: View {
    /// Author-supplied subtitles (from `project.json`) render verbatim;
    /// app-supplied subtitles flow through the localization catalog.
    enum Subtitle {
        case authorVerbatim(String)
        case localized(LocalizedStringKey)
    }

    let icon: String?
    let iconColor: Color?
    let title: String
    let subtitle: Subtitle?
    let content: Content

    init(
        icon: String? = nil,
        iconColor: Color? = nil,
        title: String,
        subtitle: Subtitle? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.iconColor = iconColor ?? (icon != nil ? .accentColor : nil)
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let icon = icon, let iconColor = iconColor {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(iconColor)
                }
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if subtitle != nil {
                    subtitleText
                        .font(DesignTokens.Typography.caption)
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

/// Author-supplied strings (`.group` header / `.text` body) already routed
/// through the `project.json` localization map at parse time.
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
