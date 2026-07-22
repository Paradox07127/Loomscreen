#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct WorkshopInspectorContent: View {
    let item: WorkshopQueryItem
    let doctor: SteamCMDDoctorService
    /// nil disables the author link (plain author text).
    var onBrowseCreator: ((String, String?) -> Void)?
    /// nil → tags render as plain labels.
    var onSelectTag: ((String) -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(ScreenManager.self) private var screenManager
    @State private var installedEntry: WPEHistoryEntry?

    @AppStorage("loomscreen.workshop.blurMatureThumbnails.v1") private var blurMatureThumbnails = true
    /// One-time 18+ confirmation, shared with the grid card via `@AppStorage`.
    @AppStorage("loomscreen.workshop.matureContentConfirmed.v1") private var matureConfirmed = false
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    @State private var showingApplyPopover = false
    @State private var descriptionExpanded = false

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

                    authorRatingRow

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
        .onChange(of: item.id) { _, _ in
            refreshInstalledEntry()
            descriptionExpanded = false
        }
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

    private func requestReveal() {
        if matureConfirmed {
            matureRevealed = true
        } else {
            showingAgeConfirm = true
        }
    }

    // MARK: - Author

    @ViewBuilder
    private var authorRatingRow: some View {
        let hasAuthor = !(item.creatorPersonaName ?? "").isEmpty
        let hasRating = (item.voteScore ?? 0) > 0
        if hasAuthor || hasRating {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ratingRow
                Spacer(minLength: 0)
                authorLine
            }
        }
    }

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
                    .font(DesignTokens.Typography.body)
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
        HStack(spacing: DesignTokens.Spacing.sm) {
            downloadControl
            secondaryActionButton("Copy ID", systemImage: "doc.on.doc") { copy(String(item.id)) }
            secondaryActionButton("Open in Steam", systemImage: "safari") { openURL(item.steamCommunityURL) }
        }
    }

    private func secondaryActionButton(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(titleKey))
        .accessibilityLabel(Text(titleKey))
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch downloadPhase {
        case .downloading:
            downloadProgressControl
        case .importing:
            indeterminateDownloadControl("Importing…")
        default:
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
        .adaptiveGlassButton(.prominent)
        .controlSize(.regular)
        .disabled(!doctor.isDownloadReady || item.isBanned)
        .help(Text(doctor.isDownloadReady
                   ? "Download with SteamCMD and add it to your library"
                   : "Set up SteamCMD in Settings → Workshop → SteamCMD Doctor to enable downloads."))
    }

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
            Button { apply(entry, to: only) } label: {
                Label("Apply to \(only.name)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(.prominent)
            .controlSize(.regular)
        } else {
            Button { showingApplyPopover = true } label: { applyLabel }
                .adaptiveGlassButton(.prominent)
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

    /// Displays currently running this item — drives the active checkmark in the Apply popover.
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
            actionNote(message, color: DesignTokens.Colors.Status.danger)
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
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if item.isBanned {
            Label("Unavailable — removed or hidden on Steam", systemImage: "xmark.octagon.fill")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(DesignTokens.Colors.Status.danger)
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

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        if let onSelectTag {
            Button { onSelectTag(tag) } label: {
                Text(tag)
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(tag)"))
        } else {
            Text(tag)
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private var descriptionSection: some View {
        let text = item.shortDescription
        let placeholder = String(localized: "No description provided.", comment: "Placeholder when a Workshop item has no description.")
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Description")
                .font(.headline)
            CollapsibleDescription(
                text: text.isEmpty ? placeholder : text,
                isExpanded: $descriptionExpanded
            )
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

/// Shared display-target chooser for the Apply popover (online + installed inspectors).
/// The caller dismisses the popover after a row fires its callback.
struct WorkshopApplyTargetPicker: View {
    let screens: [Screen]
    let activeScreenIDs: Set<CGDirectDisplayID>
    let onPick: (Screen) -> Void
    let onAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apply to")
                .font(DesignTokens.Typography.captionEmphasized)
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

/// Description block shared by the online + Installed inspectors.
struct CollapsibleDescription: View {
    let text: String
    @Binding var isExpanded: Bool

    /// ~6 lines of body copy before we crop + fade.
    private let collapsedHeight: CGFloat = 116

    /// Measured live; `max()` keeps it stable even while the visible frame is cropped
    /// (the crop never shrinks the intrinsic height).
    @State private var fullHeight: CGFloat = 0

    private var isExpandable: Bool { fullHeight > collapsedHeight + 1 }

    var body: some View {
        let collapsed = isExpandable && !isExpanded
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { fullHeight = max(fullHeight, geo.size.height) }
                            .onChange(of: geo.size.height) { _, height in
                                fullHeight = max(fullHeight, height)
                            }
                    }
                )
                .frame(height: fullHeight == 0 ? nil : (collapsed ? collapsedHeight : fullHeight),
                       alignment: .top)
                .clipped()
                .mask(collapsed ? AnyView(fadeMask) : AnyView(Rectangle()))

            if isExpandable {
                Text(isExpanded ? "Show less" : "Show more")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isExpandable else { return }
            withAnimation(.easeInOut(duration: 0.28)) { isExpanded.toggle() }
        }
        .onChange(of: text) { _, _ in
            fullHeight = 0
            isExpanded = false
        }
    }

    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.72),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
