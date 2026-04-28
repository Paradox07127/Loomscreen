import SwiftUI
import AVFoundation

struct AerialThumbnailCard: View {
    let asset: AerialAsset
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @State private var thumbnail: NSImage?
    @State private var formatInfo: VideoFormatInfo?

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailContainer
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 12,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: 12
                        )
                    )
                    .overlay(alignment: .topTrailing) {
                        formatBadgeRow
                            .padding(8)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if let category = asset.category, !category.isEmpty {
                        Text(category)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 0
                    )
                )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isHovering || isFocused ? 1.02 : 1.0)
        .shadow(
            color: .black.opacity(isHovering || isFocused ? 0.22 : 0.06),
            radius: isHovering || isFocused ? 10 : 4,
            y: isHovering || isFocused ? 4 : 2
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isHovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: isFocused)
        .onHover { isHovering = $0 }
        .task { await loadThumbnailIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let category = asset.category, !category.isEmpty {
            return "Aerial: \(asset.displayName), \(category)"
        }
        return "Aerial: \(asset.displayName)"
    }

    @ViewBuilder
    private var formatBadgeRow: some View {
        if let badges = formatInfo?.badges, !badges.isEmpty {
            HStack(spacing: 4) {
                ForEach(badges, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(badges.joined(separator: ", "))
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

    private func loadThumbnailIfNeeded() async {
        guard thumbnail == nil else { return }

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

        // Format detection is cheap (just metadata reads) and runs alongside
        // thumbnail extraction while the security scope is active.
        if let info = try? await PlayableVideoLoader.detectFormat(at: url) {
            await MainActor.run { self.formatInfo = info }
        }

        let avAsset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        do {
            let image = try await generator.image(at: .zero).image
            await MainActor.run {
                self.thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        } catch {
            // Placeholder remains; surfacing this error in UI would be noise for a thumbnail.
        }
    }
}
