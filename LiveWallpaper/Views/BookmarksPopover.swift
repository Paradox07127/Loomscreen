import LiveWallpaperCore
import LiveWallpaperSharedUI
import SwiftUI

/// Inspector-header popover for quick-saving the current wallpaper. The full
/// library list deliberately lives only on the sidebar Bookmarks page —
/// duplicating it here turned the quick-save flow into a scrollable picker.
struct BookmarksPopover: View {
    let screen: Screen
    /// Content the inspector is currently showing — passed in so a video
    /// already bookmarked doesn't light up the button when the user has
    /// switched to the HTML tab. nil = "no content for this tab yet"
    /// (renders the guidance message).
    let candidateContent: WallpaperContent?

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.dismiss) private var dismiss

    @State private var store = BookmarkStore.shared
    @State private var nameDraft: String = ""
    @State private var draftInitializedFor: UUID?
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        Group {
            if let candidateContent {
                form(for: candidateContent)
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
                .font(DesignTokens.Typography.caption)
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
                    .font(DesignTokens.Typography.badge)
                    .foregroundStyle(.secondary)
                TextField(defaultLabel(for: content), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(DesignTokens.Typography.body)
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
                .font(DesignTokens.Typography.bodyEmphasized)
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
        case .video(let bookmarkData, _):
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
        case .monitor:
            return String(localized: "Monitor", comment: "Bookmark source label for the system monitor wallpaper.")
        }
    }
}
