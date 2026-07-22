#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Shared filter chrome for the Workshop tabs.
struct WorkshopFiltersToggle: View {
    @Binding var isExpanded: Bool
    let activeFilterCount: Int
    var isDisabled: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filters")
                if activeFilterCount > 0 {
                    Text(verbatim: "\(activeFilterCount)")
                        .font(DesignTokens.Typography.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .help(Text("Filter options"))
        .accessibilityLabel(Text("Filters"))
        .accessibilityValue(activeFilterCount > 0
            ? Text("\(activeFilterCount) active")
            : Text("None active"))
    }
}

/// A category label pinned to the first chip row (top-aligned so it stays put
/// when chips wrap onto several lines).
struct WorkshopFilterRow<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .frame(width: 74, alignment: .leading)
                .padding(.top, 4)
            content
        }
    }
}

enum WorkshopFilterMath {
    /// A category narrows results only when a non-empty proper subset is
    /// selected (selecting all — or none — means "no filter").
    static func isNarrowing<T>(_ selected: Set<T>, total: Int) -> Bool {
        !selected.isEmpty && selected.count < total
    }
}
#endif
