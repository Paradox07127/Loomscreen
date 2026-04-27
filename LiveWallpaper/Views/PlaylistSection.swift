import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Unified playlist UI: primary + extras share one drag-reorderable list,
/// with star (primary) + pulse (now-playing) badges per row.
struct PlaylistSection: View {
    @Binding var playlistBookmarks: [Data]
    @Binding var shufflePlaylist: Bool
    @Binding var rotationMinutes: Int?
    var screen: Screen
    var screenManager: ScreenManager

    @State private var entries: [PlaylistEntry] = []
    @State private var draggingID: PlaylistEntry.ID?

    private let rotationOptions: [(String, Int?)] = [
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
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 8))
                .disabled(entries.count < 2)
                .accessibilityLabel("Skip to previous video")

                Button(action: addVideos) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add").lineLimit(1)
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 8))
                .accessibilityLabel("Add videos to playlist")

                Button(action: { screenManager.advancePlaylist(for: screen) }) {
                    HStack(spacing: 3) {
                        Text("Next").lineLimit(1)
                        Image(systemName: "forward.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(fontSize: 11, horizontalPadding: 8))
                .disabled(entries.count < 2)
                .accessibilityLabel("Skip to next video")
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
                    .accessibilityLabel("Rotation interval")
                }

                SettingRow(icon: "shuffle", iconColor: .purple, title: "Shuffle") {
                    Toggle("", isOn: $shufflePlaylist)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: shufflePlaylist) { _, newValue in
                            screenManager.updateShufflePlaylist(newValue, for: screen)
                        }
                        .accessibilityLabel("Shuffle playlist")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loadEntries() }
        .onChange(of: screen.id) { loadEntries() }
        .onChange(of: playlistBookmarks) { loadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperConfigurationDidChange)) { notification in
            if let changedID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
               changedID == screen.id {
                loadEntries()
            }
        }
    }

    // MARK: - Sub Views

    @ViewBuilder
    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("No videos yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Drop a video on this screen, or use Add Videos below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 6)
            Spacer()
        }
    }

    @ViewBuilder
    private var entryList: some View {
        VStack(spacing: 4) {
            ForEach(entries) { entry in
                PlaylistRow(
                    entry: entry,
                    isDragging: draggingID == entry.id,
                    onSetPrimary: { setAsPrimary(entry) },
                    onPlayNow: { playNow(entry) },
                    onRemove: { remove(entry) }
                )
                .draggable(entry.id) {
                    PlaylistRow(
                        entry: entry,
                        isDragging: false,
                        onSetPrimary: {}, onPlayNow: {}, onRemove: {}
                    )
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: 240)
                }
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(itemIDs: items, target: entry.id)
                } isTargeted: { targeted in
                    if targeted { draggingID = entry.id } else if draggingID == entry.id { draggingID = nil }
                }
                .contextMenu {
                    Button("Set as Primary", systemImage: "star.fill") { setAsPrimary(entry) }
                        .disabled(entry.isPrimary)
                    Button("Play Now", systemImage: "play.fill") { playNow(entry) }
                        .disabled(entry.isPlaying)
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { remove(entry) }
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: entries.map(\.id))
    }

    // MARK: - Entry Loading

    private func loadEntries() {
        guard let config = screenManager.getConfiguration(for: screen),
              let primary = config.savedVideoBookmarkData else {
            entries = []
            return
        }
        let extras = config.playlistBookmarks ?? []
        let combined = [primary] + extras
        let cursor = config.playlistCursorIndex ?? 0
        let activeBookmark = (cursor < combined.count) ? combined[cursor] : primary

        entries = [PlaylistEntry(
            bookmark: primary,
            isPrimary: true,
            isPlaying: primary == activeBookmark,
            name: ResourceUtilities.resolveBookmarkName(primary) ?? "Primary"
        )] + extras.map {
            PlaylistEntry(
                bookmark: $0,
                isPrimary: false,
                isPlaying: $0 == activeBookmark,
                name: ResourceUtilities.resolveBookmarkName($0) ?? "Unknown"
            )
        }
    }

    // MARK: - Actions

    private func addVideos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi]
        let completion: ([URL]) -> Void = { urls in
            guard !urls.isEmpty else { return }
            SettingsManager.shared.saveLastUsedDirectory(urls[0].deletingLastPathComponent())
            for url in urls {
                if let bookmark = ResourceUtilities.createBookmark(for: url) {
                    playlistBookmarks.append(bookmark)
                }
            }
            screenManager.updatePlaylistBookmarks(playlistBookmarks, for: screen)
            loadEntries()
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

    private func setAsPrimary(_ entry: PlaylistEntry) {
        guard !entry.isPrimary else { return }
        screenManager.setPrimaryVideo(bookmark: entry.bookmark, for: screen)
    }

    private func playNow(_ entry: PlaylistEntry) {
        guard let cursor = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        screenManager.playPlaylistEntry(at: cursor, for: screen)
    }

    private func remove(_ entry: PlaylistEntry) {
        var newEntries = entries
        newEntries.removeAll(where: { $0.id == entry.id })
        applyEntries(newEntries, removedPrimary: entry.isPrimary)
    }

    private func handleDrop(itemIDs: [String], target: PlaylistEntry.ID) -> Bool {
        guard let dragged = itemIDs.first,
              dragged != target,
              let sourceIndex = entries.firstIndex(where: { $0.id == dragged }),
              let targetIndex = entries.firstIndex(where: { $0.id == target }) else {
            draggingID = nil
            return false
        }
        var newEntries = entries
        let item = newEntries.remove(at: sourceIndex)
        // Removing source shifts downstream indices left, so source<target inserts at target-1.
        let insertAt = sourceIndex < targetIndex ? max(0, targetIndex - 1) : targetIndex
        newEntries.insert(item, at: min(insertAt, newEntries.count))
        applyEntries(newEntries, removedPrimary: false)
        draggingID = nil
        return true
    }

    /// Push the new entry order into ScreenManager. If primary entry no longer
    /// exists (removed primary), promote the first remaining entry to primary.
    private func applyEntries(_ newEntries: [PlaylistEntry], removedPrimary: Bool) {
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
        let extras = working.enumerated().compactMap { idx, e in idx == primaryIndex ? nil : e.bookmark }

        entries = working
        playlistBookmarks = extras
        screenManager.replacePlaylist(primary: primary, extras: extras, for: screen)
    }
}

// MARK: - PlaylistEntry View Model

struct PlaylistEntry: Identifiable, Equatable {
    /// Stable ID: derived from bookmark + primary flag. Survives reload as
    /// long as bookmark bytes don't change, so SwiftUI ForEach identity and
    /// in-flight drag previews stay coherent.
    var id: String { "\(isPrimary ? "p" : "x"):\(bookmark.hashValue)" }
    let bookmark: Data
    var isPrimary: Bool
    var isPlaying: Bool
    var name: String
}

// MARK: - PlaylistRow

private struct PlaylistRow: View {
    let entry: PlaylistEntry
    let isDragging: Bool
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
                        .symbolEffect(.pulse, options: .repeat(.continuous), isActive: true)
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

            Text(entry.name)
                .font(.system(size: 12, weight: entry.isPlaying ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if entry.isPrimary {
                Text("Primary")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
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

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel("Remove \(entry.name)")
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
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.4 : 1.0)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.isPrimary ? "Primary " : "")\(entry.isPlaying ? "Now playing " : "")\(entry.name)")
    }

    private var rowBackground: Color {
        if entry.isPlaying { return Color.green.opacity(0.08) }
        if isHovering { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}
