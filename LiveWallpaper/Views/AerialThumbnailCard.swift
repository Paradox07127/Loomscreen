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

/// Card for a single Apple Aerial asset. Click applies the aerial; for multi-
/// display setups the click presents a SwiftUI Menu (matches `BookmarksLibraryView`
/// — no more AppKit `NSMenu.popUp(at:)` shim).
struct AerialThumbnailCard: View {
    let asset: AerialAsset
    let screens: [Screen]
    let onApply: (Screen) -> Void
    let onApplyToAll: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @State private var thumbnail: NSImage?
    @State private var formatInfo: VideoFormatInfo?

    private var cornerRadius: CGFloat { DesignTokens.Corner.md }

    var body: some View {
        actionWrapper
            .focused($isFocused)
            .scaleEffect(isLifted ? 1.02 : 1.0)
            .shadow(
                color: .black.opacity(isLifted ? 0.22 : 0.06),
                radius: isLifted ? 10 : 4,
                y: isLifted ? 4 : 2
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isHovering)
            .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isFocused)
            .onHover { hovering in
                guard !screens.isEmpty else { return }
                isHovering = hovering
            }
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

    /// Hover / focus lift is suppressed when there's no display to apply to —
    /// non-interactive tiles shouldn't animate as if they were clickable.
    private var isLifted: Bool {
        guard !screens.isEmpty else { return false }
        return isHovering || isFocused
    }

    @ViewBuilder
    private var actionWrapper: some View {
        if screens.count == 1, let only = screens.first {
            Button { onApply(only) } label: { card }
                .buttonStyle(.plain)
        } else if screens.count > 1 {
            Menu {
                ForEach(screens, id: \.id) { screen in
                    Button("Apply to \(screen.name)") { onApply(screen) }
                }
                Divider()
                Button("Apply to All Displays", action: onApplyToAll)
            } label: { card }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        } else {
            card.opacity(0.55)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailContainer
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    formatBadgeRow.padding(8)
                }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: asset.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                if let category = asset.category, !category.isEmpty {
                    Text(verbatim: category)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var accessibilityText: Text {
        if let category = asset.category, !category.isEmpty {
            return Text("Aerial: \(asset.displayName), \(category)", comment: "Aerial thumbnail a11y label. Placeholders are aerial display name and category.")
        }
        return Text("Aerial: \(asset.displayName)", comment: "Aerial thumbnail a11y label. The placeholder is the aerial display name.")
    }

    @ViewBuilder
    private var formatBadgeRow: some View {
        if let badges = formatInfo?.badges, !badges.isEmpty {
            HStack(spacing: 4) {
                ForEach(badges, id: \.self) { label in
                    Text(verbatim: label)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: badges.joined(separator: ", ")))
        }
    }

    @ViewBuilder
    private var thumbnailContainer: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)

            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "sparkles.tv")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
    }

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
            var isStale = false
            return try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
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
