#if !LITE_BUILD && DIRECT_DISTRIBUTION
import AppKit
import LiveWallpaperSharedUI
import SwiftUI

/// Vertical detail content for a single Workshop item, shown in the trailing
/// `.inspector` of the Browse grid (replaces the old detail sheet). A square
/// auto-playing hero on top, then title + rating, the download / open / copy
/// actions, metadata, tags, and the description. "Download" runs SteamCMD via
/// the configured Doctor and imports into the local library; "Open in Steam"
/// and the copy actions are always live.
struct WorkshopInspectorContent: View {
    let item: WorkshopQueryItem
    let doctor: SteamCMDDoctorService
    /// Scope the Browse grid to this item's creator (SteamID64 + persona name) —
    /// the author-link path. nil disables the link (plain author text).
    var onBrowseCreator: ((String, String?) -> Void)? = nil
    /// Scope the Browse grid to a clicked tag. nil → tags render as plain labels.
    var onSelectTag: ((String) -> Void)? = nil
    /// Dismisses the inspector. The native `.inspector` only auto-shows a toggle
    /// when a toolbar hosts one, so we surface an explicit close control here.
    var onClose: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @Environment(ScreenManager.self) private var screenManager
    /// The installed-library entry for this item, if it's already downloaded —
    /// drives the Download → Apply swap.
    @State private var installedEntry: WPEHistoryEntry?

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1") private var blurMatureThumbnails = true
    /// One-time 18+ confirmation, shared with the grid card via `@AppStorage`.
    @AppStorage("loomscreen.workshop.matureContentConfirmed.v1") private var matureConfirmed = false
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    /// Drives the multi-display target popover under the single Apply button.
    @State private var showingApplyPopover = false

    /// Blur the hero until clicked, mirroring the grid card's spoiler gate so
    /// opening details never auto-plays adult content unprompted.
    private var shouldBlurHero: Bool {
        blurMatureThumbnails && item.isMatureRated && !matureRevealed
    }

    private var downloadCoordinator: WorkshopDownloadCoordinator { .shared }
    private var downloadPhase: WorkshopDownloadCoordinator.DownloadPhase {
        downloadCoordinator.phase(for: item.id)
    }
    private var downloadProgressFraction: Double? {
        downloadCoordinator.progress[item.id]
    }
    private var downloadProgressBytes: WorkshopDownloadCoordinator.DownloadProgressBytes? {
        downloadCoordinator.progressBytes[item.id]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                hero

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    authorLine

                    metaRow
                    statusBadge

                    actionsColumn
                    downloadStatusNote

                    if !item.tags.isEmpty {
                        tagsSection
                    }

                    descriptionSection
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignTokens.Colors.pageBackground)
        .onAppear { refreshInstalledEntry() }
        .onChange(of: item.id) { _, _ in refreshInstalledEntry() }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            refreshInstalledEntry()
        }
    }

    private func refreshInstalledEntry() {
        let id = String(item.id)
        installedEntry = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            .first { $0.origin.workshopID == id }
    }

    // MARK: - Hero

    private var hero: some View {
        AnimatedGIFThumbnail(url: item.previewImageURL, playbackMode: .autoPlay, isBlurred: shouldBlurHero)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
            .onTapGesture { if shouldBlurHero { requestReveal() } }
            .overlay(alignment: .topLeading) {
                HeroCloseButton(action: onClose).padding(DesignTokens.Spacing.sm)
            }
            .padding([.horizontal, .top], DesignTokens.Spacing.lg)
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

    /// Reveal a blurred Mature hero — gated by a one-time 18+ confirmation.
    private func requestReveal() {
        if matureConfirmed {
            matureRevealed = true
        } else {
            showingAgeConfirm = true
        }
    }

    // MARK: - Author

    @ViewBuilder
    private var authorLine: some View {
        if let author = item.creatorPersonaName, !author.isEmpty {
            if let creatorID = item.creatorID, let onBrowseCreator {
                Button {
                    onBrowseCreator(creatorID, author)
                } label: {
                    HStack(spacing: 3) {
                        Text("by \(author)", comment: "Workshop item author line. Placeholder is the creator's Steam persona name.")
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(Text("Show more wallpapers from \(author)"))
                .accessibilityLabel(Text("Show more wallpapers from \(author)"))
            } else {
                Text("by \(author)", comment: "Workshop item author line. Placeholder is the creator's Steam persona name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Rating

    @ViewBuilder
    private var ratingRow: some View {
        if let score = item.voteScore, score > 0 {
            let stars = min(max(score * 5, 0), 5)
            HStack(spacing: 6) {
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: Self.starSymbol(for: index, rating: stars))
                            .foregroundStyle(.yellow)
                            .font(.system(size: 12))
                    }
                }
                Text(verbatim: stars.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(stars.formatted(.number.precision(.fractionLength(1)))) stars"))
        }
    }

    private static func starSymbol(for index: Int, rating: Double) -> String {
        let position = Double(index)
        if rating >= position + 1 { return "star.fill" }
        if rating >= position + 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    // MARK: - Actions

    private var actionsColumn: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            // Primary CTA first (Download → Apply), then the secondary external
            // link, then the tertiary copy actions — top-down by importance.
            downloadControl

            // Rating on the left, then compact equal-height icon actions on the
            // right: open the Steam page and copy the item ID. The fixed 16×16
            // label box keeps the two icon buttons identical in size regardless
            // of glyph. Labels live in tooltips + VoiceOver.
            HStack(spacing: DesignTokens.Spacing.sm) {
                ratingRow
                Spacer(minLength: 0)
                Button {
                    openURL(item.steamCommunityURL)
                } label: {
                    Image(systemName: "safari")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Open this item on the Steam Community website"))
                .accessibilityLabel(Text("Open in Steam"))

                Button {
                    copy(String(item.id))
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text("Copy the Workshop item ID"))
                .accessibilityLabel(Text("Copy ID"))
            }
        }
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch downloadPhase {
        case .downloading:
            downloadProgressControl
        case .importing:
            indeterminateDownloadControl("Importing…")
        default:
            // Once it's in the library (just downloaded OR previously installed)
            // the control becomes Apply; otherwise it's Download / Retry.
            if let installedEntry {
                applyControl(for: installedEntry)
            } else {
                downloadButton
            }
        }
    }

    private var downloadButton: some View {
        Button {
            downloadCoordinator.download(item, using: doctor)
        } label: {
            Label(downloadButtonTitle, systemImage: "arrow.down.circle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!doctor.isDownloadReady || item.isBanned)
        .help(Text(doctor.isDownloadReady
                   ? "Download with SteamCMD and add it to your library"
                   : "Set up SteamCMD in Settings → Workshop → SteamCMD Doctor to enable downloads."))
    }

    /// Prominent blue Apply — targets the open display(s), mirroring the
    /// Installed library. Shown once the item is in the local library.
    @ViewBuilder
    private func applyControl(for entry: WPEHistoryEntry) -> some View {
        let screens = screenManager.screens
        if screens.isEmpty {
            Button {} label: { applyLabel }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(true)
                .help(Text("Open a display first, then apply"))
        } else if screens.count == 1, let only = screens.first {
            // Single display: name it in the label so the action is unambiguous
            // ("Apply to Studio Display") — no picker needed.
            Button { apply(entry, to: only) } label: {
                Label("Apply to \(only.name)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else {
            // One Apply button; tapping floats a popover to pick a display or all.
            // (Single-display applies directly above; there's no standalone
            // "Apply to All" button.)
            Button { showingApplyPopover = true } label: { applyLabel }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .popover(isPresented: $showingApplyPopover, arrowEdge: .bottom) {
                    WorkshopApplyTargetPicker(
                        screens: screens,
                        activeScreenIDs: activeScreenIDs,
                        onPick: { apply(entry, to: $0); showingApplyPopover = false },
                        onAll: { for screen in screens { apply(entry, to: screen) }; showingApplyPopover = false }
                    )
                }
        }
    }

    private var applyLabel: some View {
        Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
    }

    /// Displays currently running this item — drives the active checkmark in the
    /// Apply popover.
    private var activeScreenIDs: Set<CGDirectDisplayID> {
        Set(screenManager.screens
            .filter { screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == String(item.id) }
            .map(\.id))
    }

    private func apply(_ entry: WPEHistoryEntry, to screen: Screen) {
        Task { await screenManager.activateWPEHistoryEntry(entry, for: screen) }
    }

    @ViewBuilder
    private var downloadProgressControl: some View {
        if let progress = downloadProgressFraction {
            downloadControlChrome {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: 6) {
                        Text(verbatim: progressDetailLabel(for: progress))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        cancelDownloadButton
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("Download progress"))
                        .accessibilityValue(Text(verbatim: progressDetailLabel(for: progress)))
                }
            }
            .help(Text(verbatim: progressDetailLabel(for: progress)))
        } else {
            indeterminateDownloadControl("Downloading…")
        }
    }

    private func indeterminateDownloadControl(_ title: LocalizedStringKey) -> some View {
        downloadControlChrome {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    cancelDownloadButton
                }
                // Indeterminate linear bar: steamcmd usually streams no percentage
                // for workshop items, so this animates to read as "active" and
                // matches the determinate bar's shape — the control no longer jumps
                // between a circular spinner and a bar when a percentage does arrive.
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(title))
            }
        }
    }

    private func downloadControlChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
    }

    private var cancelDownloadButton: some View {
        Button {
            downloadCoordinator.cancel(item.id)
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(Text("Cancel download"))
        .accessibilityLabel(Text("Cancel download"))
    }

    @ViewBuilder
    private var downloadStatusNote: some View {
        if case .failed(let message) = downloadPhase {
            actionNote(message, color: .red)
        } else if !doctor.isDownloadReady, downloadPhase == .idle {
            actionNote(
                String(localized: "Downloads use SteamCMD (Settings → Workshop → SteamCMD Doctor), separate from the Web API key.", comment: "Hint in the Workshop detail inspector when SteamCMD isn't configured."),
                color: .secondary
            )
        }
    }

    private func actionNote(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isRetry: Bool {
        if case .failed = downloadPhase { return true }
        return false
    }

    /// Typed `LocalizedStringKey` so the ternary literals localize (a bare
    /// `String` ternary would bind to `Label`'s non-localized initializer).
    private var downloadButtonTitle: LocalizedStringKey { isRetry ? "Retry" : "Download" }

    private func progressDetailLabel(for fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        guard let totalBytes = downloadProgressTotalBytes else { return "\(percent)%" }

        let estimatedDownloaded = UInt64((Double(Int64(clamping: totalBytes)) * fraction).rounded())
        let downloadedBytes = downloadProgressBytes?.downloaded ?? estimatedDownloaded
        let downloadedText = Self.progressByteFormatter.string(fromByteCount: Int64(clamping: downloadedBytes))
        let totalText = Self.progressByteFormatter.string(fromByteCount: Int64(clamping: totalBytes))
        return "\(percent)% · \(downloadedText) / \(totalText)"
    }

    private var downloadProgressTotalBytes: UInt64? {
        if let total = downloadProgressBytes?.total, total > 0 {
            return total
        }
        if let fileSize = item.fileSizeBytes, fileSize > 0 {
            return fileSize
        }
        return nil
    }

    // MARK: - Metadata

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let count = item.subscriptionCount, count > 0 {
                Text(formatSubs(count))
                Text(verbatim: "·").foregroundStyle(.tertiary)
            }
            if let updated = item.timeUpdated {
                Text("Updated \(Self.dateFormatter.string(from: updated))")
                if item.fileSizeBytes != nil {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
            }
            if let size = item.fileSizeBytes {
                Text(verbatim: Self.byteFormatter.string(fromByteCount: Int64(clamping: size)))
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isBanned {
            Label("Unavailable — removed or hidden on Steam", systemImage: "xmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tagsSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(item.tags, id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    /// A tag pill. Tappable (accent-tinted) when `onSelectTag` is wired — clicking
    /// scopes the grid to that tag; otherwise a plain secondary label.
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        if let onSelectTag {
            Button { onSelectTag(tag) } label: {
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(tag)"))
        } else {
            Text(tag)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Divider()
            Text("Description")
                .font(.headline)
            Text(item.shortDescription.isEmpty
                 ? String(localized: "No description provided.", comment: "Placeholder when a Workshop item has no description.")
                 : item.shortDescription)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(value, forType: .string)
    }

    private func formatSubs(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM subs", locale: .current, Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fK subs", locale: .current, Double(count) / 1_000.0)
        }
        return "\(count) subs"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let progressByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}

/// Shared display-target chooser for the Apply popover (online + installed
/// inspectors): "All Displays" plus one row per display, the active one(s)
/// checkmarked. Picking a row fires the matching callback; the caller dismisses
/// the popover.
struct WorkshopApplyTargetPicker: View {
    let screens: [Screen]
    let activeScreenIDs: Set<CGDirectDisplayID>
    let onPick: (Screen) -> Void
    let onAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apply to")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            row(Text("All Displays"), systemImage: "rectangle.on.rectangle", action: onAll)
            Divider().padding(.horizontal, 8).padding(.vertical, 2)
            ForEach(screens, id: \.id) { screen in
                row(Text(verbatim: screen.name),
                    systemImage: activeScreenIDs.contains(screen.id) ? "checkmark.circle.fill" : "display") {
                    onPick(screen)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(minWidth: 220)
    }

    private func row(_ title: Text, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: systemImage) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
