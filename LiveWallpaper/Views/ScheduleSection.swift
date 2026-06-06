import SwiftUI
import AppKit
import LiveWallpaperCore
import LiveWallpaperSharedUI

/// Time-of-day wallpaper scheduling, aligned with `PlaylistSection`'s
/// Apple-Music language (50pt single-line rows, EQPulseBar for the
/// active slot, hover-only `⋯` menu, `AdaptiveGlass` action chips).
///
/// The 24h `ScheduleTimelineEditor` is the primary editing surface —
/// users can drag slot edges to resize, drag the middle to translate,
/// and double-tap an empty cell to insert. The row list mirrors the
/// timeline and additionally offers a wrap-aware `Menu`-picker popover
/// for keyboard / VoiceOver flows.
struct ScheduleSection: View {
    @Binding var scheduleSlots: [ScheduleSlot]
    var screen: Screen
    var screenManager: ScreenManager

    @State private var currentHour: Int = Calendar.current.component(.hour, from: Date())
    @State private var conflictHighlight: Set<UUID> = []
    @State private var addSlotErrorMessage: String?
    @State private var conflictMessage: String?
    @State private var pendingDestructive: PendingDestructive?

    /// Generation counters protect the 1.5s / 3s delayed-clear `Task`s from
    /// wiping newer UI state. Without these, a second conflict raised
    /// shortly after the first would be silently cleared when the first
    /// timer fires.
    @State private var conflictHighlightGeneration = 0
    @State private var addErrorGeneration = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let timelinePalette: [Color] = [.blue, .orange, .green, .purple]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if scheduleSlots.isEmpty {
                emptyState
            } else {
                ScheduleTimelineEditor(
                    slots: scheduleSlots,
                    currentHour: currentHour,
                    palette: Self.timelinePalette,
                    onCommitTimeChange: { id, start, end in
                        validateAndCommit(slotID: id, start: start, end: end)
                    },
                    onRequestInsert: { hour in
                        insertSlot(atHour: hour)
                    }
                )

                slotList

                if let message = addSlotErrorMessage ?? conflictMessage {
                    conflictBanner(message: message)
                }

                Divider()

                actionBar
            }
        }
        .task {
            while !Task.isCancelled {
                currentHour = Calendar.current.component(.hour, from: Date())
                let nextHour = Calendar.current.nextDate(
                    after: Date(),
                    matching: DateComponents(minute: 0, second: 0),
                    matchingPolicy: .nextTime
                ) ?? Date().addingTimeInterval(60)
                let delay = max(1, nextHour.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        .onChange(of: scheduleSlots.map(\.id)) { _, _ in
            if !conflictHighlight.isEmpty || conflictMessage != nil {
                conflictHighlightGeneration += 1
                conflictHighlight.removeAll()
                conflictMessage = nil
            }
        }
        .onChange(of: screen.id) { _, _ in
            conflictHighlightGeneration += 1
            addErrorGeneration += 1
            conflictHighlight.removeAll()
            conflictMessage = nil
            addSlotErrorMessage = nil
        }
        .confirmDestructive($pendingDestructive)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "calendar.badge.clock",
            title: "Set up a schedule",
            message: "Switch wallpapers automatically across different times of day.",
            symbolColor: .accentColor,
            primary: IllustratedEmptyState.ButtonAction("Get Started", action: enableSchedule),
            variant: .compact
        )
        .frame(maxWidth: .infinity)
    }

    // MARK: - Slot list

    @ViewBuilder
    private var slotList: some View {
        VStack(spacing: 6) {
            ForEach(Array($scheduleSlots.enumerated()), id: \.element.id) { index, $slot in
                ScheduleSlotRow(
                    slot: $slot,
                    accent: Self.timelinePalette[index % Self.timelinePalette.count],
                    isActive: slot.containsHour(currentHour),
                    isHighlightedConflict: conflictHighlight.contains(slot.id),
                    otherSlots: scheduleSlots.filter { $0.id != slot.id },
                    playlistCandidates: combinedPlaylistCandidates,
                    videoNameProvider: { screenManager.bookmarkDisplayName(for: $0) },
                    onPickFromPlaylist: { bookmark in
                        assignBookmark(bookmark, to: slot.id)
                    },
                    onPickFromFile: { selectVideo(for: slot.id) },
                    onClearVideo: { clearVideo(for: slot.id) },
                    onRemove: { removeSlot(slot.id) },
                    onCommitTimeChange: { start, end in
                        validateAndCommit(slotID: slot.id, start: start, end: end)
                    }
                )
            }
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SchedulePreset.allCases) { preset in
                    Button {
                        addSlot(from: preset)
                    } label: {
                        Label(
                            "\(preset.localized) · \(ScheduleTimeFormatter.rangeLabel(startHour: preset.hours.start, endHour: preset.hours.end))",
                            systemImage: preset.systemImage
                        )
                    }
                    .disabled(preset.conflicts(with: scheduleSlots))
                }
                Divider()
                Button {
                    addCustomSlot()
                } label: {
                    Label("Custom…", systemImage: "slider.horizontal.below.rectangle")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Slot")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(GlassCapsuleButtonStyle())
            .accessibilityLabel(Text("Add schedule slot"))

            Spacer()

            DisableScheduleButton(action: disableSchedule)
        }
    }

    // MARK: - Conflict banner

    @ViewBuilder
    private func conflictBanner(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(verbatim: message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.red.opacity(0.75))
                    .frame(width: 2)
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Schedule mutations

    private var combinedPlaylistCandidates: [Data] {
        guard let config = screenManager.getConfiguration(for: screen) else { return [] }
        return config.combinedPlaylist
    }

    private func enableSchedule() {
        scheduleSlots = ScheduleSlot.defaultSlots
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
    }

    private func disableSchedule() {
        let slotCount = scheduleSlots.count
        guard slotCount > 0 else {
            scheduleSlots = []
            screenManager.updateScheduleSlots(nil, for: screen)
            return
        }
        pendingDestructive = PendingDestructive(.disableSchedule(slotCount: slotCount)) {
            scheduleSlots = []
            screenManager.updateScheduleSlots(nil, for: screen)
        }
    }

    private func validateAndCommit(slotID: UUID, start: Int, end: Int) {
        guard let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
        let normStart = ((start % 24) + 24) % 24
        let normEnd = ((end % 24) + 24) % 24
        guard normStart != normEnd else { return }

        var probe = scheduleSlots[index]
        probe.startHour = normStart
        probe.endHour = normEnd
        let others = scheduleSlots.filter { $0.id != slotID }
        let conflicts = SchedulePolicy.conflicts(slot: probe, against: others)

        if conflicts.isEmpty {
            scheduleSlots[index].startHour = normStart
            scheduleSlots[index].endHour = normEnd
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                conflictMessage = nil
            }
            return
        }

        let labels = scheduleSlots
            .filter { conflicts.contains($0.id) }
            .map(\.localizedLabel)
            .joined(separator: ", ")
        let format = String(
            localized: "Time range overlaps with %@",
            defaultValue: "Time range overlaps with %@",
            comment: "Schedule conflict message; placeholder is a comma-separated list of overlapping slot labels."
        )
        let formatted = String(format: format, labels)
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            conflictMessage = formatted
        }

        var highlighted = conflicts
        highlighted.insert(slotID)
        conflictHighlightGeneration += 1
        let generation = conflictHighlightGeneration
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) {
            conflictHighlight = highlighted
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard generation == conflictHighlightGeneration else { return }
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                conflictHighlight.removeAll()
            }
        }
    }

    private func removeSlot(_ slotID: UUID) {
        if scheduleSlots.count <= 1 {
            pendingDestructive = PendingDestructive(.disableSchedule(slotCount: scheduleSlots.count)) {
                performRemoveSlot(slotID)
            }
            return
        }
        guard let slot = scheduleSlots.first(where: { $0.id == slotID }) else { return }
        pendingDestructive = PendingDestructive(.removeScheduleSlot(slotLabel: slot.localizedLabel)) {
            performRemoveSlot(slotID)
        }
    }

    private func performRemoveSlot(_ slotID: UUID) {
        scheduleSlots.removeAll(where: { $0.id == slotID })
        if scheduleSlots.isEmpty {
            screenManager.updateScheduleSlots(nil, for: screen)
        } else {
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        }
    }

    private func clearVideo(for slotID: UUID) {
        guard let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
        scheduleSlots[index].videoBookmarkData = nil
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
    }

    // MARK: - Add slot paths

    private func addSlot(from preset: SchedulePreset) {
        let candidate = preset.makeSlot()
        let conflicts = SchedulePolicy.conflicts(slot: candidate, against: scheduleSlots)
        guard conflicts.isEmpty else {
            flashAddError(
                String(
                    localized: "That preset overlaps an existing slot. Adjust an existing slot first.",
                    defaultValue: "That preset overlaps an existing slot. Adjust an existing slot first.",
                    comment: "Schedule error shown when a preset can't be applied because it overlaps."
                )
            )
            return
        }
        scheduleSlots.append(candidate)
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        addSlotErrorMessage = nil
    }

    private func addCustomSlot() {
        guard let free = SchedulePolicy.findFreeRange(in: scheduleSlots, minHours: 2) else {
            flashAddError(
                String(
                    localized: "No free time range. Adjust an existing slot first.",
                    defaultValue: "No free time range. Adjust an existing slot first.",
                    comment: "Schedule error shown when Add Slot cannot find a gap of at least 2 hours."
                )
            )
            return
        }
        let normalizedStart = free.start % 24
        let normalizedEnd = free.end % 24
        let preset = SchedulePreset.suggestion(forStartHour: normalizedStart)
        let candidate = ScheduleSlot(startHour: normalizedStart, endHour: normalizedEnd, label: preset.labelKey)
        // `findFreeRange` already searches against `scheduleSlots`; this
        // re-check guards against a corrupted persisted config (e.g. a
        // zero-length range that snuck past an older codepath) reaching
        // `screenManager.updateScheduleSlots` and writing junk to disk.
        guard normalizedStart != normalizedEnd,
              SchedulePolicy.conflicts(slot: candidate, against: scheduleSlots).isEmpty else {
            flashAddError(
                String(
                    localized: "No free time range. Adjust an existing slot first.",
                    defaultValue: "No free time range. Adjust an existing slot first.",
                    comment: "Schedule error shown when Add Slot cannot find a gap of at least 2 hours."
                )
            )
            return
        }
        scheduleSlots.append(candidate)
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        addSlotErrorMessage = nil
    }

    private func insertSlot(atHour hour: Int) {
        let probeEnd = (hour + 2) % 24
        let probe = ScheduleSlot(startHour: hour, endHour: probeEnd, label: SchedulePreset.suggestion(forStartHour: hour).labelKey)
        if SchedulePolicy.conflicts(slot: probe, against: scheduleSlots).isEmpty {
            scheduleSlots.append(probe)
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
            return
        }
        // 2h didn't fit — try 1h
        let oneHour = ScheduleSlot(startHour: hour, endHour: (hour + 1) % 24, label: probe.label)
        guard SchedulePolicy.conflicts(slot: oneHour, against: scheduleSlots).isEmpty else {
            flashAddError(
                String(
                    localized: "No room here. Drag a neighbouring slot edge first.",
                    defaultValue: "No room here. Drag a neighbouring slot edge first.",
                    comment: "Schedule error shown when a double-tap insertion would collide with neighbours."
                )
            )
            return
        }
        scheduleSlots.append(oneHour)
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
    }

    private func flashAddError(_ message: String) {
        addErrorGeneration += 1
        let generation = addErrorGeneration
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            addSlotErrorMessage = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard generation == addErrorGeneration else { return }
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                addSlotErrorMessage = nil
            }
        }
    }

    // MARK: - Video selection

    private func selectVideo(for slotID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.prompt = L10n.Panel.setVideo
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: parent) { response in
                guard response == .OK else { return }
                assignVideo(urls: panel.urls, to: slotID)
            }
        } else {
            guard panel.runModal() == .OK else { return }
            assignVideo(urls: panel.urls, to: slotID)
        }
    }

    private func assignVideo(urls: [URL], to slotID: UUID) {
        guard let url = urls.first else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        guard let bookmark = ResourceUtilities.createVideoBookmark(for: url) else { return }
        screenManager.recordBookmarkDisplayName(bookmark, name: url.lastPathComponent)
        assignBookmark(bookmark, to: slotID)
    }

    private func assignBookmark(_ bookmark: Data, to slotID: UUID) {
        guard let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
        scheduleSlots[index].videoBookmarkData = bookmark
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
    }
}

/// Transparent-fill capsule with red text — mirrors `GlassCapsuleButtonStyle`'s
/// geometry so the actionBar's destructive button balances Add Slot visually
/// without competing with it. Hover tints the fill subtly so the click
/// target is still discoverable when paired with a glass-filled sibling.
private struct DisableScheduleButton: View {
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(role: .destructive, action: action) {
            Text("Disable Schedule")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(Color.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isHovering ? Color.red.opacity(0.10) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel(Text("Disable schedule"))
        .accessibilityHint(Text("Removes all schedule slots and returns to normal playback"))
    }
}
