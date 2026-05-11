import SwiftUI
import AppKit

struct DetailPageScaffold<Header: View, Content: View>: View {
    let showsHeader: Bool
    private let header: Header
    private let content: Content

    init(
        showsHeader: Bool = true,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.showsHeader = showsHeader
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Divider()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.Colors.pageBackground)
    }
}

struct DetailHeaderBar<Title: View, Metadata: View, Actions: View>: View {
    let systemImage: String
    let tint: Color
    private let title: Title
    private let metadata: Metadata
    private let actions: Actions

    init(
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder title: () -> Title,
        @ViewBuilder metadata: () -> Metadata,
        @ViewBuilder actions: () -> Actions
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title()
        self.metadata = metadata()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.DetailHeader.contentSpacing) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(
                        width: DesignTokens.DetailHeader.iconSize,
                        height: DesignTokens.DetailHeader.iconSize
                    )
                Image(systemName: systemImage)
                    .font(.system(size: DesignTokens.DetailHeader.iconSymbolSize))
                    .foregroundStyle(tint)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(alignment: .leading, spacing: DesignTokens.DetailHeader.textSpacing) {
                title
                    .font(.system(size: DesignTokens.DetailHeader.titleSize, weight: .semibold))
                    .lineLimit(1)

                metadata
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: DesignTokens.Spacing.md)

            actions
        }
        .padding(.horizontal, DesignTokens.DetailHeader.horizontalPadding)
        .padding(.vertical, DesignTokens.DetailHeader.verticalPadding)
    }
}

struct GuidedLibrarySurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
