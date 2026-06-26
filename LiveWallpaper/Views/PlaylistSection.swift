import SwiftUI
import AppKit
import LiveWallpaperSharedUI

/// Drag-reorder is built on `DragGesture` + a `PreferenceKey` that tracks
/// each row's frame. We deliberately avoid SwiftUI's `.draggable` /
/// `.dropDestination` / `.onDrag` modifiers — every variant we tried on
/// macOS 14/15 had the drop event silently swallowed when source and target
/// were siblings of the same VStack. Hand-rolled gesture has no dependency
/// on AppKit's dragging-session machinery, so the reorder is deterministic.
///
/// The gesture is attached **only** to the leading-handle hit area on each
/// row so the row body can still receive double-tap to play and right-click
/// without those gestures racing.
///
/// Reorder is intentionally side-effect-free: only the visible list order
/// changes — star stays at its new position, playing video keeps playing,
/// no reload.
struct PlaylistSection: View {
    @Binding var playlistBookmarks: [Data]
    @Binding var shufflePlaylist: Bool
    @Binding var rotationMinutes: Int?
    var screen: Screen
    var screenManager: ScreenManager

    @State private var entries: [PlaylistEntry] = []
    @State private var pendingDestructive: PendingDestructive?

    // MARK: Drag-reorder state
    @State private var rowFrames: [PlaylistRowFrame] = []
    /// Snapshot of `rowFrames` taken at drag start; used in
    /// `computeInsertionIndex` instead of live `rowFrames` so the dragged
    /// row's own `.offset` can't create a feedback loop where its shifting
    /// frame perturbs the index used to decide where it should drop.
    @State private var dragSnapshotFrames: [PlaylistRowFrame]?
    @State private var draggingID: PlaylistEntry.ID?
    @State private var dragOffsetY: CGFloat = 0
    @State private var insertionIndex: Int?
    @State private var rotatePopoverShown = false

    /// Default interval (minutes) when enabling auto-rotate from `Off`.
    /// 30 is a middle-ground — neither too twitchy nor too lazy.
    private static let defaultRotationMinutes = 30
    private static let rotationMinutesRange = 1...1440

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                emptyState
            } else {
                entryList
            }

            actionBar
                .animation(.snappy(duration: 0.18), value: entries.count >= 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scheduleEntriesLoad() }
        .onChange(of: screen.id) {
            scheduleEntriesLoad()
        }
        .onChange(of: playlistBookmarks) {
            scheduleEntriesLoad()
        }
        .onChange(of: entries.count) { _, newCount in
            // If the user trims the playlist back below two entries while
            // the rotate popover is open, drop the popover state so it
            // can't be revived by SwiftUI re-presenting against a now-
            // hidden anchor button.
            if newCount < 2, rotatePopoverShown {
                rotatePopoverShown = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            guard let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
                  changedID == screen.id else { return }
            scheduleEntriesLoad()
        }
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - Sub Views

    @ViewBuilder
    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "film.stack",
            title: "No videos yet",
            message: "Drop a video on this screen, or use Add Videos below.",
            variant: .compact
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionBar: some View {
        // count <= 1: shuffle / prev / next / rotate are all functionally
        // disabled, so collapse the bar to just a centred `+` button.
        // Avoids showing four greyed-out controls to users who haven't yet
        // built up a multi-video playlist.
        if entries.count < 2 {
            HStack {
                Spacer()
                playlistIconButton(
                    systemName: "plus",
                    accessibility: Text("Add videos to playlist"),
                    help: Text("Add")
                ) { addVideos() }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.top, 4)
        } else {
            HStack(spacing: 0) {
                shuffleToggleButton

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    playlistIconButton(
                        systemName: "backward.fill",
                        accessibility: Text("Skip to previous video"),
                        help: Text("Prev")
                    ) { screenManager.regressPlaylist(for: screen) }

                    playlistIconButton(
                        systemName: "plus",
                        accessibility: Text("Add videos to playlist"),
                        help: Text("Add")
                    ) { addVideos() }

                    playlistIconButton(
                        systemName: "forward.fill",
                        accessibility: Text("Skip to next video"),
                        help: Text("Next")
                    ) { screenManager.advancePlaylist(for: screen) }
                }

                Spacer(minLength: 8)

                rotateMenuButton
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var shuffleToggleButton: some View {
        let isOn = shufflePlaylist
        let disabled = entries.count < 2
        Button {
            shufflePlaylist.toggle()
            screenManager.updateShufflePlaylist(shufflePlaylist, for: screen)
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : .secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(Text("Shuffle playlist"))
        .accessibilityLabel(Text("Shuffle playlist"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }

    @ViewBuilder
    private var rotateMenuButton: some View {
        let isActive = rotationMinutes != nil
        let disabled = entries.count < 2
        Button {
            rotatePopoverShown = true
        } label: {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : .secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.accentColor : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(Text("Rotate"))
        .accessibilityLabel(Text("Rotation interval"))
        .accessibilityValue(rotateAccessibilityValue)
        .popover(isPresented: $rotatePopoverShown, arrowEdge: .top) {
            rotatePopoverContent
        }
    }

    private var rotateAccessibilityValue: Text {
        if let minutes = rotationMinutes {
            return Text("\(minutes) minutes")
        }
        return Text("Off")
    }

    @ViewBuilder
    private var rotatePopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: autoRotateBinding) {
                Text("Auto-rotate")
                    .font(DesignTokens.Typography.body)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if rotationMinutes != nil {
                HStack(spacing: 6) {
                    TextField("", value: rotateIntervalBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(Text("Rotation interval in minutes"))
                    Stepper("", value: rotateIntervalBinding, in: Self.rotationMinutesRange)
                        .labelsHidden()
                        .accessibilityLabel(Text("Adjust rotation interval"))
                    Text("min")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 200)
    }

    private var autoRotateBinding: Binding<Bool> {
        Binding(
            get: { rotationMinutes != nil },
            set: { isOn in
                let next: Int? = isOn
                    ? max(1, rotationMinutes ?? Self.defaultRotationMinutes)
                    : nil
                rotationMinutes = next
                screenManager.updatePlaylistRotationMinutes(next, for: screen)
            }
        )
    }

    private var rotateIntervalBinding: Binding<Int> {
        Binding(
            get: { rotationMinutes ?? Self.defaultRotationMinutes },
            set: { newValue in
                let clamped = min(
                    max(newValue, Self.rotationMinutesRange.lowerBound),
                    Self.rotationMinutesRange.upperBound
                )
                rotationMinutes = clamped
                screenManager.updatePlaylistRotationMinutes(clamped, for: screen)
            }
        )
    }

    @ViewBuilder
    private func playlistIconButton(
        systemName: String,
        accessibility: Text,
        help: Text,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(help)
        .accessibilityLabel(accessibility)
    }

    @ViewBuilder
    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                insertionMarker(showAt: index)
                rowView(for: entry, index: index)
                if index < entries.count - 1 {
                    // Aligns the divider's left edge with the thumbnail's
                    // right edge: row padding 8 + handle 28 + spacing 10
                    // + thumbnail 36 = 82.
                    Divider()
                        .opacity(0.08)
                        .padding(.leading, 82)
                }
            }
            insertionMarker(showAt: entries.count)
        }
        .coordinateSpace(name: playlistCoordSpaceName)
        .onPreferenceChange(PlaylistRowFramesKey.self) { frames in
            rowFrames = frames
        }
        .animation(.snappy(duration: 0.18), value: entries.map(\.id))
    }

    @ViewBuilder
    private func insertionMarker(showAt index: Int) -> some View {
        let isActive = insertionIndex == index && draggingID != nil
        ZStack {
            if isActive {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: isActive ? 2 : 0)
    }

    @ViewBuilder
    private func rowView(for entry: PlaylistEntry, index: Int) -> some View {
        PlaylistRow(
            entry: entry,
            index: index,
            isBeingDragged: draggingID == entry.id,
            onSetPrimary: { setAsPrimary(entry) },
            onPlayNow: { playNow(entry) },
            onRemove: { remove(entry) },
            onDragChanged: { translationY, locationY in
                if draggingID != entry.id {
                    draggingID = entry.id
                    dragSnapshotFrames = rowFrames
                }
                dragOffsetY = translationY
                insertionIndex = computeInsertionIndex(pointerY: locationY)
            },
            onDragEnded: {
                let sourceID = entry.id
                let target = insertionIndex
                draggingID = nil
                dragOffsetY = 0
                insertionIndex = nil
                dragSnapshotFrames = nil
                if let target { commitReorder(sourceID: sourceID, toIndex: target) }
            }
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PlaylistRowFramesKey.self,
                    value: [PlaylistRowFrame(
                        id: entry.id,
                        frame: proxy.frame(in: .named(playlistCoordSpaceName))
                    )]
                )
            }
        )
        .offset(y: draggingID == entry.id ? dragOffsetY : 0)
        .zIndex(draggingID == entry.id ? 1 : 0)
    }

    /// Pick the insertion slot whose midpoint sits just below the pointer.
    /// Uses `dragSnapshotFrames`, not live `rowFrames` — see that field.
    private func computeInsertionIndex(pointerY: CGFloat) -> Int {
        let frames = dragSnapshotFrames ?? rowFrames
        guard !frames.isEmpty else { return 0 }
        let sorted = frames.sorted { $0.frame.minY < $1.frame.minY }
        for (idx, rowFrame) in sorted.enumerated() {
            if pointerY < rowFrame.frame.midY {
                return idx
            }
        }
        return sorted.count
    }

    private func commitReorder(sourceID: PlaylistEntry.ID, toIndex destination: Int) {
        guard let sourceIndex = entries.firstIndex(where: { $0.id == sourceID }) else { return }
        if destination == sourceIndex || destination == sourceIndex + 1 { return }

        var newEntries = entries
        let item = newEntries.remove(at: sourceIndex)
        let adjusted = sourceIndex < destination ? destination - 1 : destination
        let clamped = min(max(0, adjusted), newEntries.count)
        newEntries.insert(item, at: clamped)
        applyOrder(newEntries)
    }

    // MARK: - Entry Loading

    private func scheduleEntriesLoad() {
        DispatchQueue.main.async {
            Task { @MainActor in
                loadEntries()
            }
        }
    }

    private func loadEntries() {
        guard let config = screenManager.getConfiguration(for: screen),
              let primary = config.savedVideoBookmarkData else {
            if !entries.isEmpty { entries = [] }
            return
        }
        let combined = config.combinedPlaylist
        let storedCursor = config.playlistCursorIndex ?? 0
        // `indices.contains(_:)` defends against negative or out-of-bounds
        // values that could slip through a corrupted persisted config.
        let cursor = combined.indices.contains(storedCursor) ? storedCursor : 0
        // Identity by index so duplicate bookmark Data within the same
        // playlist still produce distinct rows (ForEach IDs, primary /
        // playing flags). Comparing by Data alone would collapse the
        // duplicates into a single SwiftUI identity.
        let primaryIndex = combined.firstIndex(of: primary)
        let nextEntries = combined.enumerated().map { index, bookmark in
            PlaylistEntry(
                id: "\(bookmark.base64EncodedString())::\(index)",
                bookmark: bookmark,
                isPrimary: index == primaryIndex,
                isPlaying: index == cursor,
                name: screenManager.bookmarkDisplayName(for: bookmark)
                    ?? String(localized: "Unknown", defaultValue: "Unknown", comment: "Fallback playlist entry name.")
            )
        }
        if entries != nextEntries { entries = nextEntries }
    }

    // MARK: - Actions

    private func addVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.prompt = L10n.Panel.addVideos
        let completion: ([URL]) -> Void = { urls in
            guard !urls.isEmpty else { return }
            SettingsManager.shared.saveLastUsedDirectory(urls[0].deletingLastPathComponent())

            // Seed with the current playlist's canonical paths, then add
            // each newly-accepted path so a single panel selection
            // containing the original file + a symlink (or the same file
            // twice) collapses to one entry.
            var existingPaths = currentPlaylistResolvedPaths()
            var skipped = 0

            for url in urls {
                let path = url.resolvingSymlinksInPath().path
                if existingPaths.contains(path) {
                    skipped += 1
                    continue
                }
                if let bookmark = ResourceUtilities.createVideoBookmark(for: url) {
                    screenManager.recordBookmarkDisplayName(bookmark, name: url.lastPathComponent)
                    playlistBookmarks.append(bookmark)
                    existingPaths.insert(path)
                }
            }
            screenManager.updatePlaylistBookmarks(playlistBookmarks, for: screen)
            loadEntries()

            if skipped > 0 {
                Logger.info("Playlist add: skipped \(skipped) duplicate(s)", category: .ui)
            }
        }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: parent) { response in
                guard response == .OK else { return }
                completion(panel.urls)
            }
        } else {
            guard panel.runModal() == .OK else { return }
            completion(panel.urls)
        }
    }

    private func currentPlaylistResolvedPaths() -> Set<String> {
        guard let config = screenManager.getConfiguration(for: screen) else { return [] }
        let combined = config.combinedPlaylist
        var paths: Set<String> = []
        for bookmarkData in combined {
            guard case .success(let resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                bookmarkData,
                target: .transient
            ) else { continue }
            paths.insert(resolved.url.resolvingSymlinksInPath().path)
        }
        return paths
    }

    private func setAsPrimary(_ entry: PlaylistEntry) {
        guard !entry.isPrimary else { return }
        screenManager.setPrimaryVideo(bookmark: entry.bookmark, for: screen)
    }

    private func playNow(_ entry: PlaylistEntry) {
        guard let cursor = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        screenManager.playPlaylistEntry(at: cursor, for: screen)
    }

    private func remove(_ entry: PlaylistEntry) {
        if entries.count == 1 {
            pendingDestructive = PendingDestructive(
                .removePlaylistItem(isLast: true, displayName: screen.name)
            ) { performRemove(entry) }
        } else {
            performRemove(entry)
        }
    }

    private func performRemove(_ entry: PlaylistEntry) {
        var newEntries = entries
        newEntries.removeAll(where: { $0.id == entry.id })
        Self.invalidateCaches(for: entry.bookmark)
        applyEntriesAfterRemove(newEntries, removedPrimary: entry.isPrimary)
    }

    /// Free the metadata + thumbnail caches the row was holding. The
    /// caches are bounded so this isn't a leak fix, but proactively
    /// dropping entries means bulk-removing a playlist returns the
    /// memory now rather than waiting for natural eviction.
    private static func invalidateCaches(for bookmark: Data) {
        WallpaperThumbnailService.shared.invalidate(
            cacheKey: AsyncRowThumbnail.cacheKey(for: bookmark)
        )
        Task.detached(priority: .utility) {
            await PlaylistMetadataService.shared.invalidate(bookmark)
        }
    }

    /// Removal path: may promote a new primary if the deleted entry was primary.
    private func applyEntriesAfterRemove(_ newEntries: [PlaylistEntry], removedPrimary: Bool) {
        guard !newEntries.isEmpty else {
            entries = []
            screenManager.clearWallpaperForScreen(screen)
            return
        }
        var working = newEntries
        if removedPrimary || !working.contains(where: { $0.isPrimary }) {
            working[0].isPrimary = true
        }
        guard let primaryIndex = working.firstIndex(where: { $0.isPrimary }) else { return }
        let primary = working[primaryIndex].bookmark
        let ordered = working.map(\.bookmark)
        let extras = ordered.enumerated().compactMap { idx, b in idx == primaryIndex ? nil : b }

        entries = working
        playlistBookmarks = extras
        screenManager.replacePlaylist(ordered: ordered, primary: primary, for: screen)
    }

    /// Pure-reorder commit: preserves primary identity + currently playing video.
    private func applyOrder(_ newEntries: [PlaylistEntry]) {
        guard let primaryIndex = newEntries.firstIndex(where: { $0.isPrimary }) else { return }
        let primary = newEntries[primaryIndex].bookmark
        let ordered = newEntries.map(\.bookmark)
        let extras = ordered.enumerated().compactMap { idx, b in idx == primaryIndex ? nil : b }

        entries = newEntries
        playlistBookmarks = extras
        screenManager.replacePlaylist(ordered: ordered, primary: primary, for: screen)
    }
}

// MARK: - PlaylistEntry View Model

struct PlaylistEntry: Identifiable, Equatable {
    /// Identity is `<bookmark>::<index>` rather than the bookmark alone so
    /// duplicate bookmark Data within the same playlist still produces
    /// distinct rows. `isPrimary` is excluded from identity so a row whose
    /// star flips animates as an update rather than delete + insert.
    let id: String
    let bookmark: Data
    var isPrimary: Bool
    var isPlaying: Bool
    var name: String
}

// MARK: - Row position tracking

let playlistCoordSpaceName = "playlist.row.space"

struct PlaylistRowFrame: Equatable, Sendable {
    let id: PlaylistEntry.ID
    let frame: CGRect
}

struct PlaylistRowFramesKey: PreferenceKey {
    static let defaultValue: [PlaylistRowFrame] = []
    static func reduce(value: inout [PlaylistRowFrame], nextValue: () -> [PlaylistRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}
