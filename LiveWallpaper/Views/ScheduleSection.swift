import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Time-of-day wallpaper scheduling UI with conflict detection + per-slot
/// add/remove. Slots can span midnight.
struct ScheduleSection: View {
    @Binding var scheduleSlots: [ScheduleSlot]
    var screen: Screen
    var screenManager: ScreenManager

    @State private var currentHour: Int = Calendar.current.component(.hour, from: Date())
    @State private var pendingSlotID: UUID?
    /// Slot IDs to flash with red outline when a stepper change conflicts.
    @State private var conflictHighlight: Set<UUID> = []
    @State private var addSlotErrorMessage: String?
    @State private var conflictMessage: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if scheduleSlots.isEmpty {
                emptyState
            } else {
                ScheduleTimelineBar(slots: scheduleSlots, currentHour: currentHour)

                ForEach($scheduleSlots) { $slot in
                    ScheduleSlotRow(
                        slot: $slot,
                        isActive: slot.containsHour(currentHour),
                        isHighlightedConflict: conflictHighlight.contains(slot.id),
                        onVideoSelect: { selectVideo(for: slot.id) },
                        onClearVideo: { clearVideo(for: slot.id) },
                        onRemove: { removeSlot(slot.id) },
                        onValidateChange: { proposedStart, proposedEnd in
                            validateAndCommit(slotID: slot.id, start: proposedStart, end: proposedEnd)
                        }
                    )
                }

                if let message = addSlotErrorMessage ?? conflictMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }

                Divider()

                HStack(spacing: 8) {
                    Button(action: addSlot) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Slot")
                        }
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                    .accessibilityLabel(Text("Add schedule slot"))

                    Spacer()

                    Button(action: disableSchedule) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Disable Schedule")
                        }
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(tint: .red))
                    .accessibilityLabel(Text("Disable schedule"))
                    .accessibilityHint(Text("Removes all schedule slots and returns to normal playback"))
                }
            }
        }
        .task {
            // Sleep precisely until the next top-of-hour so currentHour flips
            // at the boundary instead of up to 59s late.
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
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack {
            Spacer()
            Button(action: enableSchedule) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Enable Schedule")
                }
            }
            .buttonStyle(GlassCapsuleButtonStyle())
            .accessibilityLabel(Text("Enable schedule"))
            .accessibilityHint(Text("Creates time-of-day wallpaper slots"))
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func enableSchedule() {
        scheduleSlots = ScheduleSlot.defaultSlots
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
    }

    private func disableSchedule() {
        scheduleSlots = []
        screenManager.updateScheduleSlots(nil, for: screen)
    }

    private func selectVideo(for slotID: UUID) {
        pendingSlotID = slotID
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie, .avi]
        panel.prompt = L10n.Panel.setVideo
        // Attach to current key window so the panel appears on the user's active display.
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: parent) { response in
                guard response == .OK, !panel.urls.isEmpty else {
                    pendingSlotID = nil
                    return
                }
                handleImporterResult(.success(panel.urls))
            }
        } else {
            guard panel.runModal() == .OK, !panel.urls.isEmpty else {
                pendingSlotID = nil
                return
            }
            handleImporterResult(.success(panel.urls))
        }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        defer { pendingSlotID = nil }
        switch result {
        case .success(let urls):
            guard let url = urls.first, let slotID = pendingSlotID else { return }
            SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
            guard let bookmark = ResourceUtilities.createBookmark(for: url),
                  let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
            scheduleSlots[index].videoBookmarkData = bookmark
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        case .failure(let error):
            Logger.error("Schedule slot video import failed: \(error.localizedDescription)", category: .fileAccess)
        }
    }

    /// Validate a candidate stepper change against other slots; commit if no conflict,
    /// otherwise reject and flash a red outline + persistent message.
    private func validateAndCommit(slotID: UUID, start: Int, end: Int) {
        guard let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
        var probe = scheduleSlots[index]
        probe.startHour = start
        probe.endHour = end
        let others = scheduleSlots.filter { $0.id != slotID }
        let conflicts = SchedulePolicy.conflicts(slot: probe, against: others)
        if conflicts.isEmpty {
            scheduleSlots[index].startHour = start
            scheduleSlots[index].endHour = end
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) { conflictMessage = nil }
            return
        }
        // Conflict: revert stepper change, show persistent banner, flash outline 1.5s.
        let conflictingLabels = scheduleSlots
            .filter { conflicts.contains($0.id) }
            .map(\.label)
            .joined(separator: ", ")
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            conflictMessage = "Time range overlaps with: \(conflictingLabels)"
        }
        var highlighted = conflicts
        highlighted.insert(slotID)
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) { conflictHighlight = highlighted }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) { conflictHighlight.removeAll() }
        }
    }

    private func removeSlot(_ slotID: UUID) {
        scheduleSlots.removeAll(where: { $0.id == slotID })
        if scheduleSlots.isEmpty {
            screenManager.updateScheduleSlots(nil, for: screen)
        } else {
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        }
    }

    private func addSlot() {
        guard let free = SchedulePolicy.findFreeRange(in: scheduleSlots, minHours: 2) else {
            withAnimation { addSlotErrorMessage = "No free time range. Adjust an existing slot first." }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation { addSlotErrorMessage = nil }
            }
            return
        }
        let label = defaultLabel(for: free.start)
        let newSlot = ScheduleSlot(
            startHour: free.start,
            endHour: min(free.end, 24) % 24,
            label: label
        )
        scheduleSlots.append(newSlot)
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        addSlotErrorMessage = nil
    }

    private func defaultLabel(for hour: Int) -> String {
        switch hour {
        case 5..<11:  return "Morning"
        case 11..<14: return "Midday"
        case 14..<18: return "Afternoon"
        case 18..<22: return "Evening"
        default:      return "Night"
        }
    }

    private func clearVideo(for slotID: UUID) {
        if let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) {
            scheduleSlots[index].videoBookmarkData = nil
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
        }
    }
}

// MARK: - Schedule Slot Row

struct ScheduleSlotRow: View {
    @Binding var slot: ScheduleSlot
    let isActive: Bool
    let isHighlightedConflict: Bool
    let onVideoSelect: () -> Void
    let onClearVideo: () -> Void
    let onRemove: () -> Void
    /// Called on stepper change with candidate start/end. Parent validates and writes back
    /// to the binding only on success.
    let onValidateChange: (_ start: Int, _ end: Int) -> Void

    @State private var videoName: String?
    @State private var isEditingTime = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Active indicator — pulses when slot covers the current hour
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(isActive ? Color.green : Color.gray.opacity(0.3))
                    .symbolEffect(.pulse, options: .repeat(.continuous), isActive: isActive)
                    .animation(.smooth(duration: 0.3), value: isActive)

                // Slot label + time (tap to edit)
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: slot.localizedLabel)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        Text(verbatim: "\(formatHour(slot.startHour)) – \(formatHour(slot.endHour))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(isEditingTime ? .degrees(90) : .degrees(0))
                        .animation(.snappy(duration: 0.2), value: isEditingTime)
                }
                .frame(width: 90, alignment: .leading)
                .onTapGesture { withAnimation { isEditingTime.toggle() } }
                .accessibilityLabel(Text("\(slot.localizedLabel), \(formatHour(slot.startHour)) to \(formatHour(slot.endHour))", comment: "A11y label for a schedule slot. Placeholders are slot label, start time, and end time."))
                .accessibilityHint(Text("Tap to edit time range"))

                Spacer()

                // Video assignment
                if let name = videoName {
                    HStack(spacing: 4) {
                        Image(systemName: "film.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Text(verbatim: name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 80)
                        Button(action: onClearVideo) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .destructiveControlTint()
                        .accessibilityLabel(Text("Clear video for \(slot.localizedLabel)", comment: "A11y label for clearing a video from a schedule slot. The placeholder is the slot label."))
                        .accessibilityHint(Text("Removes the assigned video from this schedule slot"))
                    }
                } else {
                    Button(action: onVideoSelect) {
                        HStack(spacing: 2) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                            Text("Set Video")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Set video for \(slot.localizedLabel)", comment: "A11y label for setting a video on a schedule slot. The placeholder is the slot label."))
                    .accessibilityHint(Text("Choose a video for this schedule slot"))
                }

                Button(action: onRemove) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .destructiveControlTint()
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel(Text("Remove \(slot.localizedLabel) slot", comment: "A11y label for removing a schedule slot. The placeholder is the slot label."))
            }

            // Time range editor (toggled by tapping the time label)
            if isEditingTime {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("From")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Stepper(
                            formatHour(slot.startHour),
                            value: Binding(
                                get: { slot.startHour },
                                set: { onValidateChange(((($0 % 24) + 24) % 24), slot.endHour) }
                            ),
                            in: 0...23
                        )
                        .font(.system(size: 11))
                        .frame(width: 100)
                        .accessibilityLabel(Text("Start hour for \(slot.localizedLabel)", comment: "A11y label for a schedule slot start-hour stepper. The placeholder is the slot label."))
                        .accessibilityValue(Text(verbatim: formatHour(slot.startHour)))
                        .accessibilityHint(Text("Adjust the start time of this schedule slot"))
                    }
                    HStack(spacing: 4) {
                        Text("To")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Stepper(
                            formatHour(slot.endHour),
                            value: Binding(
                                get: { slot.endHour },
                                set: { onValidateChange(slot.startHour, ((($0 % 24) + 24) % 24)) }
                            ),
                            in: 0...23
                        )
                        .font(.system(size: 11))
                        .frame(width: 100)
                        .accessibilityLabel(Text("End hour for \(slot.localizedLabel)", comment: "A11y label for a schedule slot end-hour stepper. The placeholder is the slot label."))
                        .accessibilityValue(Text(verbatim: formatHour(slot.endHour)))
                        .accessibilityHint(Text("Adjust the end time of this schedule slot"))
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHighlightedConflict ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .animation(.snappy(duration: 0.2), value: isHighlightedConflict)
        .onHover { isHovering = $0 }
        .onAppear { resolveVideoName() }
        .onChange(of: slot.videoBookmarkData) { resolveVideoName() }
    }

    private var rowBackground: Color {
        if isHighlightedConflict { return Color.red.opacity(0.06) }
        if isHovering { return Color.primary.opacity(0.04) }
        return Color.clear
    }

    private func resolveVideoName() {
        guard let data = slot.videoBookmarkData else {
            videoName = nil
            return
        }
        videoName = ResourceUtilities.resolveBookmarkName(data) ?? "Invalid"
    }

    private func formatHour(_ hour: Int) -> String {
        let h = hour % 24
        if h == 0 { return "12AM" }
        if h == 12 { return "12PM" }
        return h < 12 ? "\(h)AM" : "\(h-12)PM"
    }
}

// MARK: - Schedule Timeline Bar

struct ScheduleTimelineBar: View {
    let slots: [ScheduleSlot]
    let currentHour: Int

    private let slotColors: [Color] = [.blue, .orange, .green, .purple]

    /// Splits midnight-wrapping slots into timeline segments.
    nonisolated static func segments(for slot: ScheduleSlot) -> [(start: Int, end: Int)] {
        if slot.startHour == slot.endHour {
            return []
        }
        if slot.startHour < slot.endHour {
            return [(slot.startHour, slot.endHour)]
        }
        // Wraps midnight — emit [start, 24) + [0, end).
        return [(slot.startHour, 24), (0, slot.endHour)]
    }

    private var activeSlotLabel: String {
        if let active = slots.first(where: { $0.containsHour(currentHour) }) {
            return active.label
        }
        return "no active slot"
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))

                // Slot segments (handles midnight wrap)
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    ForEach(Array(Self.segments(for: slot).enumerated()), id: \.offset) { _, segment in
                        let startFraction = CGFloat(segment.start) / 24.0
                        let endFraction = CGFloat(segment.end) / 24.0
                        let segmentWidth = (endFraction - startFraction) * width

                        if segmentWidth > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(slotColors[index % slotColors.count].opacity(0.6))
                                .frame(width: segmentWidth)
                                .offset(x: startFraction * width)
                        }
                    }
                }

                // Current hour marker
                let markerX = CGFloat(currentHour) / 24.0 * width
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5)
                    .offset(x: markerX)
            }
        }
        .frame(height: 20)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Schedule timeline, \(slots.count) slots, currently \(currentHour):00, active slot: \(activeSlotLabel)"))
    }
}
