import SwiftUI
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI

/// Apple Music-style schedule row (mirrors `PlaylistRow`'s 50pt cadence).
///
/// Layout:
/// ```
/// │ ● / EQ   [thumb]   Morning  6 AM — 12 PM        filename.mp4    [⋯] │
/// ```
///
/// - Leading slot: 8pt dot for inactive rows, `EQPulseBar` for the
///   currently active slot — visual parity with the playlist's
///   now-playing indicator.
/// - Time range is a button → opens `ScheduleTimeEditorPopover`.
/// - Trailing `⋯` Menu (hover-only) hosts video pick / clear / remove;
///   pulls "From Playlist" candidates from the screen's combined list.
struct ScheduleSlotRow: View {
    @Binding var slot: ScheduleSlot
    let accent: Color
    let isActive: Bool
    let isHighlightedConflict: Bool
    let otherSlots: [ScheduleSlot]
    let playlistCandidates: [Data]
    let videoNameProvider: (Data) -> String?
    let onPickFromPlaylist: (Data) -> Void
    let onPickFromFile: () -> Void
    let onClearVideo: () -> Void
    let onRemove: () -> Void
    let onCommitTimeChange: (_ start: Int, _ end: Int) -> Void

    @State private var videoName: String?
    @State private var isHovering = false
    @State private var timePopoverShown = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
                .frame(width: 16, height: 16)

            thumbnail

            VStack(alignment: .leading, spacing: 1) {
                titleRow
                subtitleRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            trailingMenu
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 50)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onAppear { resolveVideoName() }
        .onChange(of: slot.videoBookmarkData) { resolveVideoName() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: Text("Edit Time Range")) { timePopoverShown = true }
        .accessibilityAction(named: Text("Remove Slot")) { onRemove() }
    }

    // MARK: - Leading

    @ViewBuilder
    private var leadingIndicator: some View {
        if isActive {
            EQPulseBar(isPlaying: true, tint: accent)
        } else {
            Circle()
                .fill(accent.opacity(0.55))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        if let bookmark = slot.videoBookmarkData {
            AsyncRowThumbnail(bookmark: bookmark, size: 30, cornerRadius: 5)
        } else {
            placeholderThumbnail
        }
    }

    @ViewBuilder
    private var placeholderThumbnail: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [accent.opacity(0.40), accent.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "film")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            )
            .accessibilityHidden(true)
    }

    // MARK: - Title / subtitle

    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(verbatim: slot.localizedLabel)
                .font(isActive ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Button {
                timePopoverShown = true
            } label: {
                Text(verbatim: ScheduleTimeFormatter.rangeLabel(startHour: slot.startHour, endHour: slot.endHour))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.06 : 0.0))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(Text("Edit Time Range"))
            .accessibilityLabel(Text("Time range"))
            .accessibilityValue(Text(verbatim: ScheduleTimeFormatter.rangeLabel(startHour: slot.startHour, endHour: slot.endHour)))
            .popover(isPresented: $timePopoverShown, arrowEdge: .bottom) {
                ScheduleTimeEditorPopover(
                    slotID: slot.id,
                    initialStart: slot.startHour,
                    initialEnd: slot.endHour,
                    otherSlots: otherSlots,
                    onCommit: { start, end in
                        timePopoverShown = false
                        onCommitTimeChange(start, end)
                    },
                    onCancel: { timePopoverShown = false }
                )
            }
        }
    }

    @ViewBuilder
    private var subtitleRow: some View {
        if let name = videoName {
            Text(verbatim: name)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("No video assigned")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Trailing menu

    @ViewBuilder
    private var trailingMenu: some View {
        Menu {
            videoPickMenu
            if slot.videoBookmarkData != nil {
                Divider()
                Button("Clear video", systemImage: "xmark.circle", role: .destructive, action: onClearVideo)
            }
            Divider()
            Button("Remove Slot", systemImage: "trash", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .opacity(isHovering ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel(Text("More actions"))
    }

    @ViewBuilder
    private var videoPickMenu: some View {
        if !playlistCandidates.isEmpty {
            Menu {
                ForEach(playlistCandidates, id: \.self) { bookmark in
                    let name = videoNameProvider(bookmark) ?? String(
                        localized: "Unknown",
                        defaultValue: "Unknown",
                        comment: "Fallback label for a bookmark whose display name is unknown."
                    )
                    Button {
                        onPickFromPlaylist(bookmark)
                    } label: {
                        Text(verbatim: name)
                    }
                    .disabled(bookmark == slot.videoBookmarkData)
                }
            } label: {
                Label("From Playlist", systemImage: "list.and.film")
            }
        }
        Button("Choose File…", systemImage: "folder", action: onPickFromFile)
    }

    // MARK: - Visual style

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
            .fill(backgroundFill)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovering)
    }

    private var backgroundFill: Color {
        if isHighlightedConflict { return DesignTokens.Colors.Status.danger.opacity(0.10) }
        if isActive { return accent.opacity(0.10) }
        if isHovering { return Color.primary.opacity(0.04) }
        return Color.primary.opacity(0.025)
    }

    private var borderColor: Color {
        if isHighlightedConflict { return DesignTokens.Colors.Status.danger.opacity(0.75) }
        if isActive { return accent.opacity(0.30) }
        return Color.primary.opacity(0.06)
    }

    private var borderWidth: CGFloat {
        isHighlightedConflict || isActive ? 1 : 0.5
    }

    private func resolveVideoName() {
        guard let data = slot.videoBookmarkData else {
            videoName = nil
            return
        }
        videoName = videoNameProvider(data) ?? String(
            localized: "Invalid bookmark",
            defaultValue: "Invalid bookmark",
            comment: "Subtitle shown on a schedule slot whose stored bookmark can no longer be resolved."
        )
    }

    private var accessibilityLabel: Text {
        var components: [String] = [
            slot.localizedLabel,
            ScheduleTimeFormatter.rangeLabel(startHour: slot.startHour, endHour: slot.endHour),
        ]
        if let name = videoName {
            components.append(name)
        } else {
            components.append(String(
                localized: "No video assigned",
                defaultValue: "No video assigned",
                comment: "VoiceOver label for a schedule slot without a video."
            ))
        }
        if isActive {
            components.append(String(
                localized: "Active now",
                defaultValue: "Active now",
                comment: "VoiceOver tag for the schedule slot whose window matches the current hour."
            ))
        }
        return Text(verbatim: components.joined(separator: ", "))
    }
}
