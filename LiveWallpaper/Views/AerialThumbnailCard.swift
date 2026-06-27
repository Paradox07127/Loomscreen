import SwiftUI
import AVFoundation
import LiveWallpaperSharedUI

struct AerialThumbnailCacheKey: Hashable {
    private let path: String
    private let fileSize: Int64

    init(asset: AerialAsset) {
        path = asset.url.standardizedFileURL.path
        fileSize = asset.fileSize ?? -1
    }
}

private struct AerialThumbnailCacheEntry {
    let thumbnail: NSImage?
    let formatInfo: VideoFormatInfo?
}

@MainActor
private final class AerialThumbnailCache {
    static let shared = AerialThumbnailCache()

    /// Sized for 4K monitors with large Aerials libraries (200+) where a
    /// smaller window thrashes the decode pipeline on scroll.
    private let capacity = 128
    private var entries: [AerialThumbnailCacheKey: AerialThumbnailCacheEntry] = [:]
    private var recency: [AerialThumbnailCacheKey] = []

    func entry(for key: AerialThumbnailCacheKey) -> AerialThumbnailCacheEntry? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry
    }

    func insert(_ entry: AerialThumbnailCacheEntry, for key: AerialThumbnailCacheKey) {
        entries[key] = entry
        touch(key)
        trim()
    }

    private func touch(_ key: AerialThumbnailCacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func trim() {
        while recency.count > capacity {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }
}

/// Aerials are managed by macOS, so there is no rename / delete affordance and
/// tapping the tile is a no-op.
struct AerialThumbnailCard: View {
    let asset: AerialAsset
    let screens: [Screen]
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void

    @State private var isHovering = false
    @State private var thumbnail: NSImage?
    @State private var formatInfo: VideoFormatInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumbnailTile
            metadata
        }
        .contextMenu { contextMenu }
        .task { await loadThumbnailIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityActions {
            if screens.count == 1, let only = screens.first {
                Button("Apply") { onApply(only) }
            } else if screens.count > 1 {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Button("Apply to All Displays", action: onApplyToAll)
            }
        }
    }

    // MARK: Thumbnail tile

    private var thumbnailTile: some View {
        ZStack {
            tileBackground
            tileContent
            formatBadgeRow
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .galleryTileChrome(isHovering: isHovering)
        .onHover { hovering in
            guard !screens.isEmpty else { return }
            isHovering = hovering
        }
    }

    private var tileBackground: some View {
        Rectangle().fill(Color.accentColor.opacity(0.12))
    }

    @ViewBuilder
    private var tileContent: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor.opacity(0.85))
        }
    }

    @ViewBuilder
    private var formatBadgeRow: some View {
        if let badges = formatInfo?.badges, !badges.isEmpty {
            HStack(spacing: 4) {
                ForEach(badges, id: \.self) { badge in
                    Text(verbatim: badge.displayLabel)
                        .font(DesignTokens.Typography.badge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: badges.map(\.displayLabel).joined(separator: ", ")))
        }
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(alignment: .center, spacing: 8) {
            textBlock
            Spacer(minLength: 4)
            applyControl
        }
        .padding(.horizontal, 2)
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: asset.displayName)
                .font(DesignTokens.Typography.bodyEmphasized)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let category = asset.category, !category.isEmpty {
                Text(verbatim: category)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var applyControl: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { applyIcon }
            .buttonStyle(.plain)
            .help(Text("Apply"))
        } else if screens.count > 1 {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: { applyIcon }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Apply"))
        }
    }

    private var applyIcon: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.accentColor.opacity(0.95)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !screens.isEmpty {
            ForEach(screens, id: \.id) { screen in
                Button("Apply to \(screen.name)") { onApply(screen) }
            }
            if screens.count > 1 {
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            }
        }
    }

    // MARK: Accessibility

    private var accessibilityText: Text {
        if let category = asset.category, !category.isEmpty {
            return Text("Aerial: \(asset.displayName), \(category)", comment: "Aerial thumbnail a11y label. Placeholders are aerial display name and category.")
        }
        return Text("Aerial: \(asset.displayName)", comment: "Aerial thumbnail a11y label. The placeholder is the aerial display name.")
    }

    // MARK: Thumbnail loader

    @MainActor
    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil else { return }

        let cacheKey = AerialThumbnailCacheKey(asset: asset)
        if let cached = AerialThumbnailCache.shared.entry(for: cacheKey) {
            thumbnail = cached.thumbnail
            formatInfo = cached.formatInfo
            if cached.thumbnail != nil { return }
        }

        let bookmarkData = asset.bookmarkData
        let resolved: URL? = await Task.detached { () -> URL? in
            try? SecurityScopedBookmarkResolver.shared
                .resolve(bookmarkData, target: .transient).get().url
        }.value

        guard let url = resolved else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        var loadedFormatInfo = formatInfo
        if let info = try? await PlayableVideoLoader.detectFormat(at: url) {
            guard !Task.isCancelled else { return }
            loadedFormatInfo = info
            formatInfo = info
        }

        let avAsset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        do {
            let image = try await generator.image(at: .zero).image
            guard !Task.isCancelled else { return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            thumbnail = nsImage
            AerialThumbnailCache.shared.insert(
                AerialThumbnailCacheEntry(thumbnail: nsImage, formatInfo: loadedFormatInfo),
                for: cacheKey
            )
        } catch {
            if loadedFormatInfo != nil {
                AerialThumbnailCache.shared.insert(
                    AerialThumbnailCacheEntry(thumbnail: nil, formatInfo: loadedFormatInfo),
                    for: cacheKey
                )
            }
        }
    }
}
