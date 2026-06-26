import SwiftUI

/// Liquid-glass uppercase type pill ("SCENE" / "VIDEO" / "WEB") shared by
/// content cards and inspectors. Optional leading glyph and tint.
public struct TypeBadge: View {
    private let title: String
    private let systemImage: String?
    private let tint: Color?

    public init(_ title: String, systemImage: String? = nil, tint: Color? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: systemImage == nil ? 0 : 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(DesignTokens.Typography.badge)
            }
            Text(verbatim: title.uppercased(with: .current))
                .font(DesignTokens.Typography.badge)
                .tracking(0.5)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .adaptiveGlassSurface(.capsule, tint: tint)
        // A type pill is a single short word ("SCENE" / "VIDEO" / "WEB"); never
        // let a crowded row wrap or compress it — keep its intrinsic width.
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
    }

    private var foreground: AnyShapeStyle {
        tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
    }
}
