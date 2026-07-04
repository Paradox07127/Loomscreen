import SwiftUI

public struct SettingsStickySectionTitle: Equatable, Sendable, Identifiable {
    public enum Presentation: Equatable, Sendable {
        case localizedKey
        case verbatim
    }

    public let value: String
    public let presentation: Presentation

    public var id: String {
        switch presentation {
        case .localizedKey:
            return "localized-\(value)"
        case .verbatim:
            return "verbatim-\(value)"
        }
    }

    public static func localizedKey(_ value: String) -> Self {
        Self(value: value, presentation: .localizedKey)
    }

    public static func verbatim(_ value: String) -> Self {
        Self(value: value, presentation: .verbatim)
    }

    var text: Text {
        switch presentation {
        case .localizedKey:
            Text(LocalizedStringKey(value), bundle: .main)
        case .verbatim:
            Text(verbatim: value)
        }
    }
}

public struct SettingsStickySectionHeaderMeasurement: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: SettingsStickySectionTitle
    public let minY: CGFloat

    public init(id: String, title: SettingsStickySectionTitle, minY: CGFloat) {
        self.id = id
        self.title = title
        self.minY = minY
    }
}

public enum SettingsStickySectionHeaderResolver {
    public static func activeHeader(
        in measurements: [SettingsStickySectionHeaderMeasurement],
        stickyTopY: CGFloat
    ) -> SettingsStickySectionHeaderMeasurement? {
        guard !measurements.isEmpty else { return nil }

        let sorted = measurements.sorted { lhs, rhs in
            if lhs.minY == rhs.minY {
                return lhs.id < rhs.id
            }
            return lhs.minY < rhs.minY
        }

        if let reached = sorted.last(where: { $0.minY <= stickyTopY }) {
            return reached
        }

        return sorted.first
    }
}

public struct SettingsStickySectionHeader: View {
    private let title: SettingsStickySectionTitle

    public init(_ titleKey: String) {
        self.title = .localizedKey(titleKey)
    }

    public init(verbatim title: String) {
        self.title = .verbatim(title)
    }

    public var body: some View {
        title.text
            .font(DesignTokens.Typography.sectionTitle)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SettingsStickySectionHeaderPreferenceKey.self,
                        value: [
                            SettingsStickySectionHeaderMeasurement(
                                id: title.id,
                                title: title,
                                minY: proxy.frame(in: .named(SettingsStickySectionCoordinateSpace.name)).minY
                            )
                        ]
                    )
                }
            }
    }
}

public extension View {
    func settingsStickySectionChrome() -> some View {
        modifier(SettingsStickySectionChromeModifier())
    }
}

private enum SettingsStickySectionCoordinateSpace {
    static let name = "LiveWallpaper.SettingsStickySectionCoordinateSpace"
}

private struct SettingsStickySectionHeaderPreferenceKey: PreferenceKey {
    static let defaultValue: [SettingsStickySectionHeaderMeasurement] = []

    static func reduce(
        value: inout [SettingsStickySectionHeaderMeasurement],
        nextValue: () -> [SettingsStickySectionHeaderMeasurement]
    ) {
        value.append(contentsOf: nextValue())
    }
}

private struct SettingsStickySectionChromeModifier: ViewModifier {
    @State private var activeTitle: SettingsStickySectionTitle?

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: SettingsStickySectionCoordinateSpace.name)
            .onPreferenceChange(SettingsStickySectionHeaderPreferenceKey.self) { measurements in
                activeTitle = SettingsStickySectionHeaderResolver.activeHeader(
                    in: measurements,
                    stickyTopY: DesignTokens.Settings.stickyHeaderTopThreshold
                )?.title
            }
            .overlay(alignment: .top) {
                if let activeTitle {
                    SettingsStickySectionHeaderBar(title: activeTitle)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct SettingsStickySectionHeaderBar: View {
    let title: SettingsStickySectionTitle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack {
            title.text
                .font(DesignTokens.Typography.sectionTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: DesignTokens.Settings.stickyHeaderHeight)
        .background {
            ZStack(alignment: .bottom) {
                if reduceTransparency {
                    DesignTokens.Colors.pageBackground
                } else {
                    Rectangle().fill(.regularMaterial)
                }
                Rectangle()
                    .fill(DesignTokens.Colors.separator.opacity(0.32))
                    .frame(height: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}
