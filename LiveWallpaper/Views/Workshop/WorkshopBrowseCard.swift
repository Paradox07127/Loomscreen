#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Grid card for the online browse view. Square preview tile matching the
/// ~192px source thumbnails (no 16:9 letterboxing). Per-item actions live in
/// the detail sheet and right-click context menu, not on the tile.
struct WorkshopBrowseCard: View {
    let item: WorkshopQueryItem
    var isInLibrary: Bool = false
    var isSelected: Bool = false
    var onSelect: () -> Void = {}

    @State private var isHovered = false
    /// Ephemeral by design — recreated tiles (paging, filter change, relaunch) blur again.
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1") private var blurMatureThumbnails = true
    /// One-time 18+ confirmation, shared with the detail inspector via `@AppStorage`.
    @AppStorage("loomscreen.workshop.matureContentConfirmed.v1") private var matureConfirmed = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldBlur: Bool {
        blurMatureThumbnails && item.isMatureRated && !matureRevealed
    }

    var body: some View {
        // A real Button (not a tap gesture) so the tile is keyboard-focusable and
        // Return/Space activates it. A blurred tile's first activation reveals it;
        // a second opens details.
        Button(action: { if shouldBlur { requestReveal() } else { onSelect() } }) {
            VStack(alignment: .leading, spacing: 0) {
                thumbnailArea
                textInfo
                    .padding(DesignTokens.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .galleryTileChrome(isHovering: isHovered, isSelected: isSelected, cornerRadius: DesignTokens.Corner.lg, reduceMotion: reduceMotion)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .help(item.title)
        .contextMenu { contextMenuItems }
        // Collapse the rich tile into one labeled element; per-item actions stay on the rotor.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(shouldBlur
            ? Text("Mature content hidden. Activate to reveal.")
            : Text("Show details"))
        .accessibilityAction(named: Text("Open in Steam")) {
            guard !item.isBanned else { return }
            openURL(item.steamCommunityURL)
        }
        .accessibilityAction(named: Text("Copy link")) { copy(item.steamCommunityURL.absoluteString) }
        .accessibilityAction(named: Text("Copy ID")) { copy(String(item.id)) }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                matureConfirmed = true
                matureRevealed = true
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    /// Gated by a one-time 18+ confirmation (remembered across the app once accepted).
    private func requestReveal() {
        if matureConfirmed {
            matureRevealed = true
        } else {
            showingAgeConfirm = true
        }
    }

    // MARK: - Thumbnail

    private var thumbnailArea: some View {
        ZStack(alignment: .topLeading) {
            AnimatedGIFThumbnail(
                url: item.previewImageURL,
                playbackMode: .hoverToPlay,
                isBlurred: shouldBlur,
                isHovered: $isHovered
            )

            if let rating = ratingValue, !shouldBlur {
                ratingPill(rating)
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isInLibrary {
                inLibraryBadge
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let resolutionLabel, !shouldBlur {
                resolutionPill(resolutionLabel)
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func resolutionPill(_ label: String) -> some View {
        Text(verbatim: label)
            .font(DesignTokens.Typography.badge)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .thumbnailBadgeGlass()
            .accessibilityHidden(true)
    }

    private var inLibraryBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("In Library")
                .font(DesignTokens.Typography.badge)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass(tint: Self.inLibraryGreen, opacity: 0.85)
        .accessibilityHidden(true)
    }

    private func ratingPill(_ rating: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: rating.formatted(.number.precision(.fractionLength(1))))
                .font(DesignTokens.Typography.badge)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .thumbnailBadgeGlass()
        .accessibilityHidden(true)
    }

    private static let inLibraryGreen = DesignTokens.Colors.badgeActive

    // MARK: - Footer

    private var textInfo: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(item.title)
                .font(DesignTokens.Typography.bodyEmphasized)
                // Reserve two lines so 1- and 2-line titles produce equal-height cards (no ragged grid).
                .lineLimit(2, reservesSpace: true)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if let type = contentType {
                    TypeBadge(type.displayName, systemImage: Self.typeSymbol(for: type))
                }
                Spacer(minLength: 4)
                if let subs = subscribersLabel {
                    HStack(spacing: 2) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8, weight: .semibold))
                        Text(verbatim: subs)
                            .font(DesignTokens.Typography.badge)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityHidden(true)
                }
            }

            statusBadge
        }
    }

    /// Leading type glyph, matching the app's existing drag-preview iconography
    /// (`WorkshopInstalledView.dragIconName`) so Scene/Video/Web read the same
    /// everywhere.
    private static func typeSymbol(for type: WorkshopContentTypeFilter) -> String? {
        switch type {
        case .scene: return "cube.transparent.fill"
        case .video: return "play.rectangle.fill"
        case .web: return "globe"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let status = statusInfo {
            HStack(spacing: 4) {
                Image(systemName: status.symbol)
                    .foregroundStyle(status.tint)
                    .imageScale(.small)
                Text(verbatim: status.text)
                    .font(DesignTokens.Typography.captionEmphasized)
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

    /// `voteScore` is 0...1; map to a 0...5 star value.
    private var ratingValue: Double? {
        guard let score = item.voteScore, score > 0 else { return nil }
        return min(max(score * 5, 0), 5)
    }

    private var contentType: WorkshopContentTypeFilter? {
        let lowered = Set(item.tags.map { $0.lowercased() })
        if lowered.contains("scene") { return .scene }
        if lowered.contains("video") { return .video }
        if lowered.contains("web") { return .web }
        return nil
    }

    /// VoiceOver names this via `accessibilityLabelText`, so the visible badge is
    /// `accessibilityHidden`. Download size was moved off the narrow card to the
    /// detail sheet so the type pill never has to wrap.
    private var subscribersLabel: String? {
        guard let subs = item.subscriptionCount, subs > 0 else { return nil }
        return formatSubs(subs)
    }

    private var resolutionLabel: String? {
        Self.resolutionShortLabel(for: item.tags)
    }

    static func resolutionShortLabel(for tags: [String]) -> String? {
        for tag in tags {
            if let mapped = knownResolutionLabels[tag] { return mapped }
        }
        for tag in tags {
            if let derived = deriveResolutionLabel(from: tag) { return derived }
        }
        return nil
    }

    private static let knownResolutionLabels: [String: String] = [
        "Standard Definition": "SD",
        "1280 x 720": "720p",
        "1920 x 1080": "1080p",
        "2560 x 1440": "1440p",
        "3840 x 2160": "4K",
        "2560 x 1080": "UW",
        "3440 x 1440": "UW",
        "Dual 3840 x 1080": "Dual",
        "5120 x 1440": "Dual",
        "7680 x 2160": "Dual",
        "1080 x 1920": "Portrait",
        "720 x 1280": "Portrait",
        "1440 x 2560": "Portrait",
        "2160 x 3840": "Portrait"
    ]

    /// Derive a label from any embedded "W x H" tag (covers prefixes like
    /// "Dual 3840 x 1080"). Ratio buckets ultrawide/dual; height buckets the
    /// landscape resolutions.
    private static func deriveResolutionLabel(from tag: String) -> String? {
        guard tag.range(of: #"\d+\s*[xX×]\s*\d+"#, options: .regularExpression) != nil else { return nil }
        let nums = tag.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        let width = nums[nums.count - 2], height = nums[nums.count - 1]
        guard width > 0, height > 0 else { return nil }
        if height > width { return "Portrait" }
        let ratio = Double(width) / Double(height)
        if ratio >= 3.0 { return "Dual" }
        if ratio >= 2.0 { return "UW" }
        switch height {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        default: return "SD"
        }
    }

    private var formattedSize: String? {
        guard let bytes = item.fileSizeBytes else { return nil }
        // `fileSizeBytes` is `UInt64`; clamp before the `Int64` formatter to
        // avoid a trap on a pathological value.
        return Self.byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    /// Single source for the restricted/banned badge, reused by VoiceOver.
    private var statusInfo: (text: String, tint: Color, symbol: String)? {
        if item.isBanned {
            return (String(localized: "Unavailable", comment: "Workshop item removed or hidden on Steam."), DesignTokens.Colors.Status.danger, "xmark.octagon.fill")
        }
        switch item.visibility {
        case .friendsOnly:
            return (String(localized: "Friends-only", comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        case .private:
            return (String(localized: "Private", comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
        case .public, .unknown:
            return nil
        @unknown default:
            return (String(localized: "Restricted", comment: "Workshop item visibility."), DesignTokens.Colors.Status.warning, "exclamationmark.triangle.fill")
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
        if let resolutionLabel {
            parts.append(resolutionLabel)
        }
        if let subs = item.subscriptionCount, subs > 0 {
            parts.append(String(localized: "\(formatSubs(subs)) subscribers", comment: "Workshop card VoiceOver subscriber count."))
        }
        if let size = formattedSize {
            parts.append(size)
        }
        if isInLibrary {
            parts.append(String(localized: "In Library", comment: "Workshop card VoiceOver: item is already downloaded to the local library."))
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
