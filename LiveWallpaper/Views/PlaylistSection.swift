import SwiftUI

/// Playlist management UI showing the primary video + additional videos,
/// with shuffle, drag-to-reorder, and time-based rotation interval.
struct PlaylistSection: View {
    @Binding var playlistBookmarks: [Data]
    @Binding var shufflePlaylist: Bool
    @Binding var rotationMinutes: Int?
    var screen: Screen
    var screenManager: ScreenManager

    @State private var primaryVideoName: String = "Current Video"
    @State private var resolvedNames: [String] = []

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
            // Now Playing (primary video)
            if screen.videoPlayer != nil {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                    Text(primaryVideoName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("Now Playing")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityLabel("Now playing: \(primaryVideoName)")
            }

            // Additional playlist items
            if !playlistBookmarks.isEmpty {
                Divider()

                List {
                    ForEach(Array(resolvedNames.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 10))
                                .foregroundStyle(.quaternary)

                            Image(systemName: "film")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            Text(name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button(action: { removeVideo(at: index) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(name)")
                        }
                        .padding(.vertical, 1)
                        .accessibilityLabel("Playlist item \(index + 1): \(name)")
                    }
                    .onMove(perform: moveVideo)
                }
                .listStyle(.plain)
                .frame(height: min(CGFloat(resolvedNames.count) * 30, 150))
            }

            // Add button
            Button(action: addVideos) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Videos")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add videos to playlist")

            // Controls (only shown when playlist has items)
            if !playlistBookmarks.isEmpty {
                Divider()

                // Manual advance button
                Button(action: { screenManager.advancePlaylist(for: screen) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "forward.fill")
                        Text("Next Video")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip to next video")

                Divider()

                // Rotation interval
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

                // Shuffle toggle
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
        .onAppear {
            resolvePrimaryVideoName()
            resolveBookmarkNames()
        }
        .onChange(of: playlistBookmarks) { resolveBookmarkNames() }
    }

    // MARK: - Actions

    private func addVideos() {
        let panel = ResourceUtilities.configureVideoOpenPanel()
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls {
                    if let bookmark = ResourceUtilities.createBookmark(for: url) {
                        playlistBookmarks.append(bookmark)
                    }
                }
                screenManager.updatePlaylistBookmarks(playlistBookmarks, for: screen)
                resolveBookmarkNames()
            }
        }
    }

    private func moveVideo(from source: IndexSet, to destination: Int) {
        playlistBookmarks.move(fromOffsets: source, toOffset: destination)
        screenManager.updatePlaylistBookmarks(playlistBookmarks, for: screen)
        resolveBookmarkNames()
    }

    private func removeVideo(at index: Int) {
        guard index < playlistBookmarks.count else { return }
        playlistBookmarks.remove(at: index)
        screenManager.updatePlaylistBookmarks(playlistBookmarks, for: screen)
        resolveBookmarkNames()
    }

    private func resolvePrimaryVideoName() {
        guard let config = screenManager.getConfiguration(for: screen) else { return }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: config.videoBookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            primaryVideoName = url.lastPathComponent
        }
    }

    private func resolveBookmarkNames() {
        resolvedNames = playlistBookmarks.compactMap { data in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return "Unknown" }
            return url.lastPathComponent
        }
    }
}
