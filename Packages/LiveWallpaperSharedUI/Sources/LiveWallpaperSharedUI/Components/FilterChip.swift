import SwiftUI

/// Translucent pill used inside `LibraryFilterBar` (or any toolbar-style
/// horizontal control row) to expose a small enumerated filter. The selected
/// state stays subtle to match Apple Music / News chip rows — brightened
/// surface + slightly stronger border, never a hard accent fill.
public struct FilterChip: View {
    private let title: Text
    private let isSelected: Bool
    private let action: () -> Void

    public init(title: Text, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            title
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isSelected
                            ? Color.accentColor.opacity(0.15)
                            : Color.primary.opacity(0.07)
                    )
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
