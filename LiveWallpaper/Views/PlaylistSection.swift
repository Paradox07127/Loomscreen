import SwiftUI

/// Playlist management UI for adding/removing videos and controlling shuffle mode.
struct PlaylistSection: View {
    @Binding var playlistBookmarks: [Data]
    @Binding var shufflePlaylist: Bool
    var screen: Screen
    var screenManager: ScreenManager

    @State private var resolvedNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Playlist items
            if playlistBookmarks.isEmpty {
                HStack {
                    Spacer()
                    Text("No additional videos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
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
            .accessibilityHint("Opens a file picker to select additional videos")

            Divider()

            // Shuffle toggle
            SettingRow(icon: "shuffle", iconColor: .purple, title: "Shuffle") {
                Toggle("", isOn: $shufflePlaylist)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: shufflePlaylist) { _, newValue in
                        screenManager.updateShufflePlaylist(newValue, for: screen)
                    }
                    .accessibilityLabel("Shuffle playlist")
                    .accessibilityHint("Randomize the playback order of playlist videos")
            }
        }
        .onAppear { resolveBookmarkNames() }
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
