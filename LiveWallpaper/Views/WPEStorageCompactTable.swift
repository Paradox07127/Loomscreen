#if !LITE_BUILD
import SwiftUI
import LiveWallpaperSharedUI

/// One row of the compact, macOS-Storage-style file table.
struct WPEStorageRowItem: Identifiable, Sendable {
    let id: String
    let icon: String
    let title: String
    /// Localized type label (e.g. "Scene"); empty hides the Kind column cell.
    let kind: String
    let sizeText: String
    /// Folder to reveal in Finder, when the item has a reachable one.
    let folderURL: URL?
}

/// Dense, single-line file list modeled on the macOS "Storage → Documents"
/// management table: small type icon · Name · Kind · right-aligned Size, fixed
/// compact row height, alternating row tint, hover-revealed reveal-in-Finder
/// action, and a fixed-height internal scroll so a large library never floods
/// the settings page. FLAT per the app's locked visual language (glass is for
/// floating chrome, not content lists).
struct WPEStorageCompactTable: View {
    let items: [WPEStorageRowItem]
    /// When true the row area fills the offered height (for a sheet); otherwise
    /// it sizes to content and caps at `maxVisibleRows` (for inline use).
    var fill: Bool = false
    let onOpen: (URL) -> Void

    private let rowHeight: CGFloat = 30
    private let maxVisibleRows = 10
    private let kindWidth: CGFloat = 80
    private let sizeWidth: CGFloat = 74
    private let actionWidth: CGFloat = 24
    private var corner: CGFloat { DesignTokens.Corner.md }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Fill mode (sheet): take all offered height. Inline mode: size to
            // content and only wrap in a ScrollView when it overflows, so an
            // inner ScrollView in the Form doesn't hijack the wheel for a few rows.
            if fill {
                ScrollView {
                    LazyVStack(spacing: 0) { rows }
                }
            } else if items.count > maxVisibleRows {
                ScrollView {
                    LazyVStack(spacing: 0) { rows }
                }
                .frame(height: CGFloat(maxVisibleRows) * rowHeight)
            } else {
                VStack(spacing: 0) { rows }
            }
        }
        .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color.primary.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            WPEStorageTableRow(
                item: item,
                isAlternate: !index.isMultiple(of: 2),
                rowHeight: rowHeight,
                kindWidth: kindWidth,
                sizeWidth: sizeWidth,
                actionWidth: actionWidth,
                onOpen: onOpen
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Name")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Kind")
                .frame(width: kindWidth, alignment: .leading)
            HStack(spacing: 3) {
                Text("Size")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .frame(width: sizeWidth, alignment: .trailing)
            Color.clear.frame(width: actionWidth)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct WPEStorageTableRow: View {
    let item: WPEStorageRowItem
    let isAlternate: Bool
    let rowHeight: CGFloat
    let kindWidth: CGFloat
    let sizeWidth: CGFloat
    let actionWidth: CGFloat
    let onOpen: (URL) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(verbatim: item.title)
                .font(DesignTokens.Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(Text(verbatim: item.title))

            Text(verbatim: item.kind)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: kindWidth, alignment: .leading)

            Text(verbatim: item.sizeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: sizeWidth, alignment: .trailing)

            // Always in the tree (a11y reaches it via the row action below);
            // opacity only reveals it on hover so the layout never shifts.
            Group {
                if let url = item.folderURL {
                    Button { onOpen(url) } label: {
                        Image(systemName: "folder").font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .opacity(isHovered ? 1 : 0)
                    .help(Text("Open folder for \(item.title)", comment: "Storage row action. Placeholder is the wallpaper title."))
                }
            }
            .frame(width: actionWidth)
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAction(named: Text("Open folder for \(item.title)", comment: "Storage row action. Placeholder is the wallpaper title.")) {
            if let url = item.folderURL { onOpen(url) }
        }
    }

    private var accessibilityText: String {
        [item.title, item.kind, item.sizeText].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var rowBackground: Color {
        if isHovered { return Color.primary.opacity(0.07) }
        return isAlternate ? Color.primary.opacity(0.035) : Color.clear
    }
}
#endif
