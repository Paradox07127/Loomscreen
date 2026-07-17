#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Trailing detail inspector for an installed item. Apply happens here
/// (per-display via the mini-map, or "All"); drag-onto-display is the quick path.
struct WPEInstalledInspectorContent: View {
    /// Derived boolean state for the item (bookmark + update availability),
    /// grouped so the caller sets a labelled bundle rather than four loose
    /// same-typed flags. (Named `ItemState`, not `State`, so it doesn't shadow
    /// SwiftUI's `@State` property wrapper inside this view.)
    struct ItemState {
        let isBookmarked: Bool
        let canBookmark: Bool
        let hasUpdate: Bool
        let canUpdate: Bool
    }

    /// Per-item callbacks. `onSelectTag` is wired only when tags should be
    /// tappable (jump to Browse Online by tag).
    struct Actions {
        let onApply: (Screen) -> Void
        let onApplyToAll: () -> Void
        let onUpdate: () -> Void
        let onToggleBookmark: () -> Void
        let onShowInFinder: () -> Void
        let onDelete: () -> Void
        let onSelectTag: ((String) -> Void)?
    }

    let entry: WPEHistoryEntry
    let screens: [Screen]
    let activeScreenIDs: Set<CGDirectDisplayID>
    let state: ItemState
    let actions: Actions

    @Environment(\.openURL) private var openURL
    @State private var showingApplyPopover = false
    /// WPE metadata read from the item's local `project.json` — no Steam API.
    /// nil until the off-main read completes; reloaded when the entry changes.
    @State private var localInfo: WPELocalProjectInfo?
    @State private var localInfoLoadOwner = WorkshopInstalledLocalInfoLoadOwner()
    @State private var descriptionExpanded = false

    /// Shared singleton — reading it here makes this view observe the
    /// re-download's phase + progress.
    private var downloadCoordinator: WorkshopDownloadCoordinator { .shared }
    private var itemID: UInt64? { UInt64(entry.origin.workshopID) }
    private var updatePhase: WorkshopDownloadCoordinator.DownloadPhase {
        guard let itemID else { return .idle }
        return downloadCoordinator.phase(for: itemID)
    }
    private var isUpdateRetry: Bool {
        if case .failed = updatePhase { return true }
        return false
    }
    private var localInfoLoadIdentity: WorkshopInstalledLocalInfoLoadIdentity {
        WorkshopInstalledLocalInfoLoadIdentity(entryID: entry.id, importedAt: entry.importedAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                hero
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text(verbatim: entry.origin.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DesignTokens.Spacing.xs) {
                        typePill
                        if let rating = localInfo?.contentRating, !rating.isEmpty {
                            contentRatingPill(rating)
                        }
                    }
                    metaRow
                    if state.hasUpdate { updateSection }
                    unsupportedWarning
                    if !activeScreenIDs.isEmpty { inUseRow }

                    applySection

                    infoSection
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignTokens.Colors.pageBackground)
        .task(id: localInfoLoadIdentity) {
            let ticket = localInfoLoadOwner.begin(identity: localInfoLoadIdentity)
            descriptionExpanded = false
            let loadedInfo = await loadWPELocalProjectInfo(for: entry)
            guard localInfoLoadOwner.canPublish(ticket) else { return }
            localInfo = loadedInfo
        }
        .onDisappear { localInfoLoadOwner.invalidate() }
    }

    private var hero: some View {
        WPEPreviewView(
            imageURL: entry.origin.sourcePreviewURL,
            securityScopedBookmarkData: entry.origin.sourceFolderBookmark,
            playbackMode: .hoverToPlay
        )
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .padding([.horizontal, .top], DesignTokens.Spacing.lg)
    }

    /// All local (no API). Size shows instantly from the persisted measurement,
    /// or once the first off-main folder scan lands; the date is always available.
    private var metaRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Group {
                if let bytes = entry.sizeBytes ?? localInfo?.sizeBytes, bytes > 0 {
                    Label {
                        Text(verbatim: Self.byteFormatter.string(fromByteCount: bytes))
                    } icon: {
                        Image(systemName: "internaldrive")
                    }
                }
                Label {
                    Text(entry.importedAt, format: .dateTime.year().month().day())
                } icon: {
                    Image(systemName: "calendar")
                }
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Spacer(minLength: DesignTokens.Spacing.sm)

            if state.canBookmark || state.isBookmarked {
                plainIconButton(
                    state.isBookmarked ? "Remove Bookmark" : "Add Bookmark",
                    systemImage: state.isBookmarked ? "bookmark.fill" : "bookmark",
                    tint: state.isBookmarked ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary),
                    action: actions.onToggleBookmark
                )
            }
            if let url = steamURL {
                plainIconButton("Steam", systemImage: "arrow.up.forward.app", tint: AnyShapeStyle(.secondary)) {
                    openURL(url)
                }
            }
        }
    }

    private func plainIconButton(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        tint: AnyShapeStyle,
        size: CGFloat = 13,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(titleKey))
        .accessibilityLabel(Text(titleKey))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private var typePill: some View {
        TypeBadge(entry.origin.localizedDisplayTypeName, systemImage: entry.origin.originalType.symbolName)
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Update available on Steam", systemImage: "arrow.triangle.2.circlepath")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(DesignTokens.Colors.Status.warning)

            switch updatePhase {
            case .downloading, .importing:
                updateProgressRow
            default:
                Button(action: actions.onUpdate) {
                    Label(isUpdateRetry ? "Retry Update" : "Update", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.canUpdate)
                .help(state.canUpdate
                      ? Text("Re-download the latest version from Steam")
                      : Text("Set up SteamCMD in Settings → Workshop to enable updates."))

                if case .failed(let message) = updatePhase {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !state.canUpdate {
                    Text("Updates use SteamCMD (Settings → Workshop → SteamCMD Doctor).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var updateProgressRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let itemID, let fraction = downloadCoordinator.progress[itemID] {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(updatePhase == .importing ? "Importing…" : "Downloading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                if let itemID { downloadCoordinator.cancel(itemID) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Cancel update"))
            .accessibilityLabel(Text("Cancel update"))
        }
    }

    @ViewBuilder
    private var unsupportedWarning: some View {
        if entry.origin.originalType == .application || entry.origin.originalType == .unknown {
            Label("This is a Windows-only wallpaper and can't run on macOS.", systemImage: "exclamationmark.triangle.fill")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inUseRow: some View {
        let names = screens.filter { activeScreenIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
        return Label("In use on \(names)", systemImage: "checkmark.circle.fill")
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.Status.active)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var applySection: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            applyControl
            plainIconButton("Show in Finder", systemImage: "folder", tint: AnyShapeStyle(.secondary), size: 15, action: actions.onShowInFinder)
            plainIconButton("Remove", systemImage: "trash", tint: AnyShapeStyle(DesignTokens.Colors.Status.danger), size: 15, action: actions.onDelete)
        }
    }

    @ViewBuilder
    private var applyControl: some View {
        if screens.isEmpty {
            Button {} label: {
                Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(true)
            .help(Text("Open a display first, then apply"))
        } else if screens.count == 1, let only = screens.first {
            Button { actions.onApply(only) } label: {
                Label("Apply to \(only.name)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(.prominent)
            .controlSize(.regular)
        } else {
            Button { showingApplyPopover = true } label: {
                Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .adaptiveGlassButton(.prominent)
            .controlSize(.regular)
            .popover(isPresented: $showingApplyPopover, arrowEdge: .bottom) {
                WorkshopApplyTargetPicker(
                    screens: screens,
                    activeScreenIDs: activeScreenIDs,
                    onPick: { actions.onApply($0); showingApplyPopover = false },
                    onAll: { actions.onApplyToAll(); showingApplyPopover = false }
                )
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        if let info = localInfo, info.hasContent {
            if let description = info.cleanedDescription, !description.isEmpty {
                descriptionSection(description)
            }
            if !info.tags.isEmpty {
                tagsSection(info.tags)
            }
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Description").font(.headline)
            CollapsibleDescription(
                text: text,
                isExpanded: $descriptionExpanded
            )
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    tagChip(tag)
                }
            }
        }
    }

    /// Tappable accent chip when `onSelectTag` is wired; otherwise inert.
    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        if let onSelectTag = actions.onSelectTag {
            Button { onSelectTag(tag) } label: {
                Text(verbatim: tag)
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(tag)"))
        } else {
            Text(verbatim: tag)
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
    }

    private func contentRatingPill(_ rating: String) -> some View {
        let tint = contentRatingTint(rating)
        return Text(verbatim: rating.uppercased(with: .current))
            .font(DesignTokens.Typography.badge)
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    private func contentRatingTint(_ rating: String) -> Color {
        switch rating.lowercased() {
        case "everyone": return .green
        case "questionable": return .orange
        case "mature": return .red
        default: return .gray
        }
    }

    private var steamURL: URL? {
        guard UInt64(entry.origin.workshopID) != nil else { return nil }
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(entry.origin.workshopID)")
    }
}

#endif
