#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Grid card for the online browse view. macOS-native gallery idiom: a square
/// preview tile (matching the ~192px source thumbnails — no 16:9 letterboxing),
/// an always-on star rating pill in the top-left derived from
/// `WorkshopQueryItem.voteScore`, and a compact title + type / subscriptions /
/// size footer. Per-item actions live in the detail sheet (tap / Return) and a
/// right-click context menu, keeping the tile itself clean.
struct WorkshopBrowseCard: View {
    let item: WorkshopQueryItem
    /// Invoked when the card is activated — opens the detail sheet.
    var onSelect: () -> Void = {}

    @State private var isHovered = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A real Button (not a tap gesture) so the tile is keyboard-focusable
        // and Return/Space activates it. `galleryTileChrome` owns the single
        // clip + hairline stroke + resting/hover shadow + 1.02× lift for the
        // whole card, so the call site contributes only the artwork + footer.
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailArea
                textInfo
                    .padding(DesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .buttonStyle(.plain)
        .galleryTileChrome(isHovering: isHovered, cornerRadius: DesignTokens.Corner.lg, reduceMotion: reduceMotion)
        .onHover { isHovered = $0 }
        .help(item.title)
        .contextMenu { contextMenuItems }
        // Collapse the rich tile into one labeled element carrying the same
        // metadata sighted users see; the per-item actions stay on the rotor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text("Show details"))
        .accessibilityAction(named: Text("Open in Steam")) {
            guard !item.isBanned else { return }
            openURL(item.steamCommunityURL)
        }
        .accessibilityAction(named: Text("Copy link")) { copy(item.steamCommunityURL.absoluteString) }
        .accessibilityAction(named: Text("Copy ID")) { copy(String(item.id)) }
    }

    // MARK: - Thumbnail

    private var thumbnailArea: some View {
        ZStack(alignment: .topLeading) {
            AnimatedGIFThumbnail(
                url: item.previewImageURL,
                playbackMode: .hoverToPlay,
                isHovered: $isHovered
            )

            if let rating = ratingValue {
                ratingPill(rating)
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ratingPill(_ rating: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: rating.formatted(.number.precision(.fractionLength(1))))
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Fixed dark scrim keeps the white glyphs legible over any thumbnail
        // (a translucent material would wash out over a light preview corner).
        .background(.black.opacity(0.7), in: Capsule())
        .accessibilityHidden(true)
    }

    // MARK: - Footer

    private var textInfo: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let type = contentType {
                    typePill(type)
                }
                Spacer(minLength: 0)
                if !metaTrailing.isEmpty {
                    Text(verbatim: metaTrailing)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            statusBadge
        }
    }

    private func typePill(_ type: WorkshopContentTypeFilter) -> some View {
        Text(verbatim: type.displayName.uppercased(with: .current))
            .font(.system(size: 9, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = statusInfo {
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .imageScale(.small)
                Text(verbatim: status.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            openURL(item.steamCommunityURL)
        } label: {
            Label("Open in Steam", systemImage: "arrow.up.forward.app")
        }
        .disabled(item.isBanned)

        Divider()

        Button {
            copy(item.steamCommunityURL.absoluteString)
        } label: {
            Label("Copy link", systemImage: "link")
        }
        Button {
            copy(String(item.id))
        } label: {
            Label("Copy ID", systemImage: "doc.on.doc")
        }
    }

    // MARK: - Derived values

    /// `voteScore` is 0...1; map to a 0...5 star value. Hidden when absent.
    private var ratingValue: Double? {
        guard let score = item.voteScore, score > 0 else { return nil }
        return min(max(score * 5, 0), 5)
    }

    /// Canonical Wallpaper Engine content type, surfaced as the footer pill via
    /// its localized display name.
    private var contentType: WorkshopContentTypeFilter? {
        let lowered = Set(item.tags.map { $0.lowercased() })
        if lowered.contains("scene") { return .scene }
        if lowered.contains("video") { return .video }
        if lowered.contains("web") { return .web }
        return nil
    }

    private var metaTrailing: String {
        var parts: [String] = []
        if let subs = item.subscriptionCount, subs > 0 {
            parts.append(String(localized: "\(formatSubs(subs)) subs", comment: "Workshop card subscriber count. Placeholder is an abbreviated number such as 1.2K."))
        }
        if let size = formattedSize {
            parts.append(size)
        }
        return parts.joined(separator: " · ")
    }

    private var formattedSize: String? {
        guard let bytes = item.fileSizeBytes else { return nil }
        // `fileSizeBytes` is `UInt64`; clamp before the `Int64` formatter to
        // avoid a trap on a pathological value.
        return Self.byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    /// Single source for the restricted/banned badge — reused by VoiceOver.
    private var statusInfo: (text: String, tint: Color, symbol: String)? {
        if item.isBanned {
            return (String(localized: "Unavailable", comment: "Workshop item removed or hidden on Steam."), .red, "xmark.octagon.fill")
        }
        switch item.visibility {
        case .friendsOnly:
            return (String(localized: "Friends-only", comment: "Workshop item visibility."), .orange, "exclamationmark.triangle.fill")
        case .private:
            return (String(localized: "Private", comment: "Workshop item visibility."), .orange, "exclamationmark.triangle.fill")
        case .public, .unknown:
            return nil
        @unknown default:
            return (String(localized: "Restricted", comment: "Workshop item visibility."), .orange, "exclamationmark.triangle.fill")
        }
    }

    private var accessibilityLabelText: String {
        var parts: [String] = [item.title]
        if let rating = ratingValue {
            parts.append(String(localized: "\(rating.formatted(.number.precision(.fractionLength(1)))) stars", comment: "Workshop card VoiceOver rating. Placeholder is a number 0–5."))
        }
        if let type = contentType {
            parts.append(type.displayName)
        }
        if let subs = item.subscriptionCount, subs > 0 {
            parts.append(String(localized: "\(formatSubs(subs)) subscribers", comment: "Workshop card VoiceOver subscriber count."))
        }
        if let size = formattedSize {
            parts.append(size)
        }
        if let status = statusInfo {
            parts.append(status.text)
        }
        return parts.joined(separator: ", ")
    }

    private func formatSubs(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", locale: .current, Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", locale: .current, Double(count) / 1_000.0)
        }
        return count.formatted()
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
#endif
