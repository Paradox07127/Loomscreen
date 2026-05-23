import SwiftUI

/// Inspector-header popover. Single-purpose: bookmark the current
/// wallpaper (or manage the existing bookmark if it's already saved).
/// The full library list lives in the sidebar-routed Bookmarks page —
/// duplicating that list here just bloated the surface and turned the
/// quick-save flow into a scrollable picker.
///
/// Three states, one compact form:
/// 1. No active wallpaper → guidance message only
/// 2. Active wallpaper, not yet bookmarked → name field + Save button
/// 3. Already bookmarked → name field pre-filled + Update / Remove
struct BookmarksPopover: View {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var store = BookmarkStore.shared
    @State private var nameDraft: String = ""
    @State private var draftInitializedFor: UUID? = nil
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        Group {
            if let content = currentContent() {
                form(for: content)
            } else {
                emptyState
            }
        }
        .padding(14)
        .frame(width: 260)
        .presentationCompactAdaptation(.popover)
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(systemImage: "bookmark", title: Text("Bookmark"))
            Text("Configure a wallpaper first to bookmark it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func form(for content: WallpaperContent) -> some View {
        let existing = store.equivalentBookmark(content: content)
        VStack(alignment: .leading, spacing: 12) {
            header(
                systemImage: existing == nil ? "bookmark" : "bookmark.fill",
                title: existing == nil ? Text("Save Bookmark") : Text("Bookmarked")
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(defaultLabel(for: content), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commit(content: content, existing: existing) }
            }

            actionRow(content: content, existing: existing)
        }
        .onAppear { syncDraft(with: existing) }
        .onChange(of: existing?.id) { _, _ in syncDraft(with: existing) }
    }

    private func header(systemImage: String, title: Text) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
            title
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    @ViewBuilder
    private func actionRow(content: WallpaperContent, existing: WallpaperBookmark?) -> some View {
        if let existing {
            HStack(spacing: 6) {
                Button(role: .destructive) {
                    pendingDestructive = PendingDestructive(
                        .deleteBookmark(bookmarkName: existing.label)
                    ) {
                        store.remove(existing.id)
                        dismiss()
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .controlSize(.small)
                .destructiveControlTint()

                Spacer()

                Button {
                    let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != existing.label else { dismiss(); return }
                    store.rename(existing.id, to: trimmed)
                    dismiss()
                } label: {
                    Text("Update")
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(updateDisabled(existing: existing))
            }
        } else {
            HStack {
                Spacer()
                Button {
                    commit(content: content, existing: nil)
                } label: {
                    Label("Save", systemImage: "plus")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Commit / sync

    private func commit(content: WallpaperContent, existing: WallpaperBookmark?) {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            guard !trimmed.isEmpty, trimmed != existing.label else { dismiss(); return }
            store.rename(existing.id, to: trimmed)
        } else {
            store.add(
                label: trimmed,
                content: content,
                sourceDisplayName: sourceDisplayName(for: content),
                playbackSettings: currentPlaybackSettings()
            )
        }
        dismiss()
    }

    /// Keep the TextField in sync with whichever bookmark (if any) matches
    /// the current wallpaper. Tracks the bookmark id we last initialized
    /// against so the user's in-progress edits aren't clobbered by
    /// `@Observable` updates from elsewhere in the app.
    private func syncDraft(with existing: WallpaperBookmark?) {
        let key = existing?.id
        guard draftInitializedFor != key else { return }
        draftInitializedFor = key
        nameDraft = existing?.label ?? ""
    }

    private func updateDisabled(existing: WallpaperBookmark) -> Bool {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == existing.label
    }

    // MARK: - Data sources

    private func currentContent() -> WallpaperContent? {
        screenManager.getConfiguration(for: screen)?.activeWallpaper
    }

    /// Snapshot the screen's full playback + effect state so the bookmark captures a complete plan, not just the content pointer.
    private func currentPlaybackSettings() -> BookmarkPlaybackSettings? {
        guard let config = screenManager.getConfiguration(for: screen) else { return nil }
        return BookmarkPlaybackSettings.snapshot(of: config)
    }

    private func defaultLabel(for content: WallpaperContent) -> String {
        BookmarkStore.defaultLabel(
            for: content,
            sourceDisplayName: sourceDisplayName(for: content)
        )
    }

    private func sourceDisplayName(for content: WallpaperContent) -> String? {
        switch content {
        case .video(let bookmarkData):
            return screenManager.bookmarkDisplayName(for: bookmarkData)
        case .html(let source, _):
            return source.displayName
        case .metalShader(let source):
            switch source {
            case .builtin(let preset): return preset.localizedTitle
            case .custom:              return String(localized: "Custom Shader", comment: "Bookmark source label for a user-imported Metal shader.")
            }
        case .scene(let descriptor):
            return String(localized: "Scene \(descriptor.workshopID)", comment: "Bookmark source label for a Wallpaper Engine scene. The placeholder is the Workshop ID.")
        }
    }
}
