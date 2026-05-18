import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Unified playlist UI: primary + extras share one reorderable list, with
/// star (primary) + pulse (now-playing) badges per row.
///
/// Drag-reorder is built on `DragGesture` + a `PreferenceKey` that tracks
/// each row's frame. We deliberately avoid SwiftUI's `.draggable` /
/// `.dropDestination` / `.onDrag` modifiers — every variant we tried on
/// macOS 14/15 had the drop event silently swallowed when source and target
/// were siblings of the same VStack. Hand-rolled gesture has no dependency
/// on AppKit's dragging-session machinery, so the reorder is deterministic.
///
/// Reorder is intentionally side-effect-free: the visible list order is
/// the only thing that changes. The starred entry keeps its star at its
/// new position, the currently-playing video keeps playing, no reload.
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
    @State private var draggingID: PlaylistEntry.ID?
    @State private var dragOffsetY: CGFloat = 0
    @State private var insertionIndex: Int?

    private let rotationOptions: [(LocalizedStringKey, Int?)] = [
        ("Off", nil),
        ("15 min", 15),
        ("30 min", 30),
        ("1 hour", 60),
        ("2 hours", 120),
        ("4 hours", 240),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                emptyState
            } else {
                entryList
            }

            HStack(spacing: 6) {
                Button(action: { screenManager.regressPlaylist(for: screen) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "backward.fill")
                        Text("Prev").lineLimit(1)
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 6))
                .disabled(entries.count < 2)
                .accessibilityLabel(Text("Skip to previous video"))

                Button(action: addVideos) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add").lineLimit(1)
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 6))
                .accessibilityLabel(Text("Add videos to playlist"))

                Button(action: { screenManager.advancePlaylist(for: screen) }) {
                    HStack(spacing: 3) {
                        Text("Next").lineLimit(1)
                        Image(systemName: "forward.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 6))
                .disabled(entries.count < 2)
                .accessibilityLabel(Text("Skip to next video"))
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if entries.count >= 2 {
                Divider()

                SettingRow(icon: "timer", iconColor: .orange, title: "Rotate") {
                    Picker("", selection: Binding(
                        get: { rotationMinutes },
                        set: { newValue in
                            rotationMinutes = newValue
                            screenManager.updatePlaylistRotationMinutes(newValue, for: screen)
                        }
                    )) {
                        ForEach(rotationOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                    .accessibilityLabel(Text("Rotation interval"))
                }

                SettingRow(icon: "shuffle", iconColor: .purple, title: "Shuffle") {
                    Toggle("", isOn: $shufflePlaylist)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: shufflePlaylist) { _, newValue in
                            screenManager.updateShufflePlaylist(newValue, for: screen)
                        }
                        .accessibilityLabel(Text("Shuffle playlist"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { scheduleEntriesLoad() }
        .onChange(of: screen.id) {
            scheduleEntriesLoad()
        }
        .onChange(of: playlistBookmarks) {
            scheduleEntriesLoad()
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
    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                insertionMarker(showAt: index)
                rowView(for: entry)
                    .padding(.vertical, 2)
            }
            insertionMarker(showAt: entries.count)
        }
        .coordinateSpace(name: PlaylistCoordSpace)
        .onPreferenceChange(PlaylistRowFramesKey.self) { frames in
            rowFrames = frames
        }
        .animation(.snappy(duration: 0.18), value: entries.map(\.id))
    }

    @ViewBuilder
    private func insertionMarker(showAt index: Int) -> some View {
        ZStack {
            if insertionIndex == index, draggingID != nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 2)
    }

    @ViewBuilder
    private func rowView(for entry: PlaylistEntry) -> some View {
        PlaylistRow(
            entry: entry,
            isBeingDragged: draggingID == entry.id,
            onSetPrimary: { setAsPrimary(entry) },
            onPlayNow: { playNow(entry) },
            onRemove: { remove(entry) }
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PlaylistRowFramesKey.self,
                    value: [PlaylistRowFrame(
                        id: entry.id,
                        frame: proxy.frame(in: .named(PlaylistCoordSpace))
                    )]
                )
            }
        )
        .offset(y: draggingID == entry.id ? dragOffsetY : 0)
        .zIndex(draggingID == entry.id ? 1 : 0)
        .contextMenu {
            Button("Set as Primary", systemImage: "star.fill") { setAsPrimary(entry) }
                .disabled(entry.isPrimary)
            Button("Play Now", systemImage: "play.fill") { playNow(entry) }
                .disabled(entry.isPlaying)
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
        }
        .gesture(reorderGesture(for: entry))
    }

    private func reorderGesture(for entry: PlaylistEntry) -> some Gesture {
        // minimumDistance > 0 so a plain click never starts a drag — the row's
        // menu / context-menu / hover affordances stay live.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(PlaylistCoordSpace))
            .onChanged { value in
                if draggingID != entry.id {
                    draggingID = entry.id
                }
                dragOffsetY = value.translation.height
                insertionIndex = computeInsertionIndex(
                    draggedID: entry.id,
                    pointerY: value.location.y
                )
            }
            .onEnded { _ in
                let sourceID = entry.id
                let target = insertionIndex
                draggingID = nil
                dragOffsetY = 0
                insertionIndex = nil
                if let target { commitReorder(sourceID: sourceID, toIndex: target) }
            }
    }

    /// Pick the insertion slot whose midpoint sits just below the pointer.
    /// Returns 0..entries.count (inclusive of the trailing slot).
    private func computeInsertionIndex(draggedID: PlaylistEntry.ID, pointerY: CGFloat) -> Int {
        guard !rowFrames.isEmpty else { return 0 }
        let sorted = rowFrames.sorted { $0.frame.minY < $1.frame.minY }
        for (idx, rowFrame) in sorted.enumerated() {
            if pointerY < rowFrame.frame.midY {
                return idx
            }
        }
        return sorted.count
    }

    /// Reorder entries locally then sync to ScreenManager. No reload, no
    /// primary change, no cursor change — just the order.
    private func commitReorder(sourceID: PlaylistEntry.ID, toIndex destination: Int) {
        guard let sourceIndex = entries.firstIndex(where: { $0.id == sourceID }) else { return }
        // Inserting right at the source position OR right after it is a no-op.
        if destination == sourceIndex || destination == sourceIndex + 1 { return }

        var newEntries = entries
        let item = newEntries.remove(at: sourceIndex)
        // Removing source shifts downstream slots left by one.
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
        let cursor = config.playlistCursorIndex ?? 0
        let activeBookmark = (cursor < combined.count) ? combined[cursor] : primary

        let nextEntries = combined.map { bookmark in
            PlaylistEntry(
                bookmark: bookmark,
                isPrimary: bookmark == primary,
                isPlaying: bookmark == activeBookmark,
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

            // Snapshot resolved paths of everything already in the visible
            // playlist (primary + extras) — playlist dedup compares by file
            // identity, not raw bookmark bytes, because security-scoped
            // bookmarks generate fresh tokens per creation and would never
            // byte-match an existing entry.
            let existingPaths = currentPlaylistResolvedPaths()
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

    /// Set of canonical file paths backing the current playlist. Used to
    /// short-circuit duplicate adds — same video file added twice would
    /// produce two consecutive plays of the same content during rotation.
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
        // Removing the only remaining entry clears the wallpaper on this display.
        // Surface a Liquid Glass confirmation so users don't lose their setup unintentionally.
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
        applyEntriesAfterRemove(newEntries, removedPrimary: entry.isPrimary)
    }

    /// Removal path: may promote a new primary if the deleted entry was
    /// primary. Distinct from the drag-reorder path so drag never touches
    /// primary identity.
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

    /// Pure-reorder commit: preserves primary identity + currently playing
    /// video. The starred entry keeps its star at its new position; the
    /// active playback bookmark is followed to its new index by the
    /// orchestrator's cursor-resolve logic.
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
    /// Identity is the bookmark — `isPrimary` is a property of the entry, not
    /// part of its identity, so a row whose primary status flips animates as
    /// an update rather than a delete + insert.
    var id: String { bookmark.base64EncodedString() }
    let bookmark: Data
    var isPrimary: Bool
    var isPlaying: Bool
    var name: String
}

// MARK: - Row position tracking

private let PlaylistCoordSpace = "playlist.row.space"

struct PlaylistRowFrame: Equatable, Sendable {
    let id: PlaylistEntry.ID
    let frame: CGRect
}

private struct PlaylistRowFramesKey: PreferenceKey {
    static let defaultValue: [PlaylistRowFrame] = []
    static func reduce(value: inout [PlaylistRowFrame], nextValue: () -> [PlaylistRowFrame]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - PlaylistRow

private struct PlaylistRow: View {
    let entry: PlaylistEntry
    let isBeingDragged: Bool
    let onSetPrimary: () -> Void
    let onPlayNow: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            ZStack {
                if entry.isPlaying {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .continuouslyRepeating, isActive: true)
                } else if entry.isPrimary {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 14)

            Text(verbatim: entry.name)
                .font(.system(size: 12, weight: entry.isPlaying ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(Text(verbatim: entry.name))

            Spacer(minLength: 4)

            if entry.isPrimary {
                Image(systemName: "star.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(width: 18, height: 18)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                    .help(Text("Primary video"))
            }

            Menu {
                Button("Set as Primary", systemImage: "star.fill", action: onSetPrimary)
                    .disabled(entry.isPrimary)
                Button("Play Now", systemImage: "play.fill", action: onPlayNow)
                    .disabled(entry.isPlaying)
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .opacity(isHovering ? 1 : 0.6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(entry.isPlaying ? Color.green.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isBeingDragged ? 0.22 : 0), radius: 8, x: 0, y: 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        switch (entry.isPrimary, entry.isPlaying) {
        case (true, true):
            return Text("Primary now playing \(entry.name)", comment: "Playlist row a11y label. The placeholder is the video name.")
        case (true, false):
            return Text("Primary \(entry.name)", comment: "Playlist row a11y label. The placeholder is the video name.")
        case (false, true):
            return Text("Now playing \(entry.name)", comment: "Playlist row a11y label. The placeholder is the video name.")
        case (false, false):
            return Text(verbatim: entry.name)
        }
    }

    private var rowBackground: Color {
        if entry.isPlaying { return Color.green.opacity(0.08) }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}
