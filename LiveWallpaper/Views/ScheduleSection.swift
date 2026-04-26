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
    /// stepper 调整若产生冲突，被影响的 slot ID 短暂高亮（红色描边）。
    @State private var conflictHighlight: Set<UUID> = []
    @State private var addSlotErrorMessage: String?

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

                if let message = addSlotErrorMessage {
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
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)).interactive(), in: .capsule)
                    .accessibilityLabel("Add schedule slot")

                    Spacer()

                    Button(action: disableSchedule) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Disable Schedule")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color.red.opacity(0.15)).interactive(), in: .capsule)
                    .accessibilityLabel("Disable schedule")
                    .accessibilityHint("Removes all schedule slots and returns to normal playback")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                currentHour = Calendar.current.component(.hour, from: Date())
                try? await Task.sleep(for: .seconds(60))
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
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)).interactive(), in: .capsule)
            .accessibilityLabel("Enable schedule")
            .accessibilityHint("Creates time-of-day wallpaper slots")
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
        // 绑定到当前 key window，让 panel 在用户操作的屏幕上弹出，
        // 避免跑到 main screen。
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

    /// stepper 改动 startHour/endHour 时调用：先用建议值构造一个临时 slot，
    /// 计算与其他 slot 的冲突。无冲突 → 提交并保存；有冲突 → 撤销改动并
    /// 短暂红框提示。
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
            return
        }
        // 冲突：撤销 stepper 改动 + 红框警示对方 slot 1.5 秒。
        var highlighted = conflicts
        highlighted.insert(slotID)
        withAnimation(.snappy(duration: 0.18)) { conflictHighlight = highlighted }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(.snappy(duration: 0.2)) { conflictHighlight.removeAll() }
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
    /// stepper 调整时调用，传入候选的 startHour/endHour 让上层做冲突校验。
    /// 若校验通过上层会直接写回 binding；不通过则不写回。
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
                        Text(slot.label)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        Text("\(formatHour(slot.startHour)) – \(formatHour(slot.endHour))")
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
                .accessibilityLabel("\(slot.label), \(formatHour(slot.startHour)) to \(formatHour(slot.endHour))")
                .accessibilityHint("Tap to edit time range")

                Spacer()

                // Video assignment
                if let name = videoName {
                    HStack(spacing: 4) {
                        Image(systemName: "film.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        Text(name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 80)
                        Button(action: onClearVideo) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear video for \(slot.label)")
                        .accessibilityHint("Removes the assigned video from this schedule slot")
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
                    .accessibilityLabel("Set video for \(slot.label)")
                    .accessibilityHint("Choose a video for this schedule slot")
                }

                Button(action: onRemove) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .accessibilityLabel("Remove \(slot.label) slot")
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
                            onIncrement: { onValidateChange((slot.startHour + 1) % 24, slot.endHour) },
                            onDecrement: { onValidateChange((slot.startHour + 23) % 24, slot.endHour) }
                        )
                        .font(.system(size: 11))
                        .frame(width: 100)
                        .accessibilityLabel("Start hour for \(slot.label)")
                        .accessibilityValue(formatHour(slot.startHour))
                        .accessibilityHint("Adjust the start time of this schedule slot")
                    }
                    HStack(spacing: 4) {
                        Text("To")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Stepper(
                            formatHour(slot.endHour),
                            onIncrement: { onValidateChange(slot.startHour, (slot.endHour + 1) % 24) },
                            onDecrement: { onValidateChange(slot.startHour, (slot.endHour + 23) % 24) }
                        )
                        .font(.system(size: 11))
                        .frame(width: 100)
                        .accessibilityLabel("End hour for \(slot.label)")
                        .accessibilityValue(formatHour(slot.endHour))
                        .accessibilityHint("Adjust the end time of this schedule slot")
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

    /// Splits a slot into one or two `(startHour, endHour)` segments so slots that
    /// wrap midnight (e.g. 22 → 6) still render correctly.
    ///
    /// Exposed as `internal static` so unit tests can pin down the boundary
    /// behavior (normal, wrapping, zero-length) without standing up a SwiftUI
    /// view hierarchy.
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
        .accessibilityLabel("Schedule timeline, \(slots.count) slots, currently \(currentHour):00, active slot: \(activeSlotLabel)")
    }
}
