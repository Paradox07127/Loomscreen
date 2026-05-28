#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Grid card variant for the online browse view. Visual idiom matches
/// `WorkshopPasteRowCard` but in a vertical / thumbnail-on-top layout
/// suitable for `LazyVGrid`.
struct WorkshopBrowseCard: View {
    let item: WorkshopQueryItem

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailArea
                .galleryTileChrome(isHovering: isHovered, cornerRadius: DesignTokens.Corner.lg, reduceMotion: reduceMotion)
                .onHover { isHovered = $0 }
                .onTapGesture { openURL(item.steamCommunityURL) }
                .help(item.title)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("\(item.title) — Open in Steam"))
            infoArea
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
        .accessibilityElement(children: .contain)
        .task(id: item.previewImageURL) { await loadThumbnail() }
    }

    private var thumbnailArea: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipped()
                    .accessibilityHidden(true)
            } else if item.previewImageURL != nil {
                ProgressView()
                    .controlSize(.small)
                    .opacity(0.6)
            } else {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.tertiary)
            }

            if let count = item.subscriptionCount, count > 0 {
                Text(formatSubs(count))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(8)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
    }

    private var infoArea: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !item.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }

            statusBadge

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button {
                    openURL(item.steamCommunityURL)
                } label: {
                    Label("Open in Steam", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Button("Copy link") { copy(item.steamCommunityURL.absoluteString) }
                    Button("Copy ID") { copy(String(item.id)) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isBanned {
            badge(text: "Unavailable", tint: .red, systemImage: "xmark.octagon.fill")
        } else if item.visibility != .public && item.visibility != .unknown {
            badge(text: visibilityText, tint: .orange, systemImage: "exclamationmark.triangle.fill")
        }
    }

    private func badge(text: String, tint: Color, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .imageScale(.small)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    private var visibilityText: String {
        switch item.visibility {
        case .friendsOnly: return "Friends-only"
        case .private: return "Private"
        default: return "Restricted"
        }
    }

    private var subtitleText: String? {
        var parts: [String] = []
        if let creator = item.creatorPersonaName { parts.append("by \(creator)") }
        if let updated = item.timeUpdated {
            parts.append(Self.relativeFormatter.localizedString(for: updated, relativeTo: Date()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatSubs(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM subs", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK subs", Double(count) / 1_000.0)
        }
        return "\(count) subs"
    }

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }

    private func loadThumbnail() async {
        guard let url = item.previewImageURL else { return }
        let image = await WorkshopPreviewImageLoader.shared.load(url)
        if !Task.isCancelled {
            thumbnail = image
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
#endif
