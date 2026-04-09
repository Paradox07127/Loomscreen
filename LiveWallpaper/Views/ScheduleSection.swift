import SwiftUI

/// Time-of-day wallpaper scheduling UI with 4 configurable time slots.
struct ScheduleSection: View {
    @Binding var scheduleSlots: [ScheduleSlot]
    var screen: Screen
    var screenManager: ScreenManager

    @State private var currentHour: Int = Calendar.current.component(.hour, from: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if scheduleSlots.isEmpty {
                // Enable button
                HStack {
                    Spacer()
                    Button(action: enableSchedule) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Enable Schedule")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Enable schedule")
                    .accessibilityHint("Creates time-of-day wallpaper slots")
                    Spacer()
                }
                .padding(.vertical, 4)
            } else {
                ScheduleTimelineBar(slots: scheduleSlots, currentHour: currentHour)

                ForEach($scheduleSlots) { $slot in
                    ScheduleSlotRow(
                        slot: $slot,
                        isActive: slot.containsHour(currentHour),
                        onVideoSelect: { selectVideo(for: slot.id) },
                        onClearVideo: { clearVideo(for: slot.id) },
                        onChange: { screenManager.updateScheduleSlots(scheduleSlots, for: screen) }
                    )
                }

                Divider()

                Button(action: disableSchedule) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Disable Schedule")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Disable schedule")
                .accessibilityHint("Removes all schedule slots and returns to normal playback")
            }
        }
        .task {
            // Update current hour periodically
            while !Task.isCancelled {
                currentHour = Calendar.current.component(.hour, from: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
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
        let panel = ResourceUtilities.configureVideoOpenPanel()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let bookmark = ResourceUtilities.createBookmark(for: url) {
                    if let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) {
                        scheduleSlots[index].videoBookmarkData = bookmark
                        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
                    }
                }
            }
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
    let onVideoSelect: () -> Void
    let onClearVideo: () -> Void
    let onChange: () -> Void

    @State private var videoName: String?
    @State private var isEditingTime = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                // Active indicator
                Circle()
                    .fill(isActive ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)

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
                        .animation(.easeInOut(duration: 0.2), value: isEditingTime)
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
                            value: $slot.startHour,
                            in: 0...23,
                            step: 1
                        )
                        .font(.system(size: 11))
                        .frame(width: 100)
                        .onChange(of: slot.startHour) { onChange() }
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
                            value: $slot.endHour,
                            in: 0...23,
                            step: 1
                        )
                        .font(.system(size: 11))
                        .frame(width: 100)
                        .onChange(of: slot.endHour) { onChange() }
                        .accessibilityLabel("End hour for \(slot.label)")
                        .accessibilityValue(formatHour(slot.endHour))
                        .accessibilityHint("Adjust the end time of this schedule slot")
                    }
                }
                .padding(.leading, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .onAppear { resolveVideoName() }
        .onChange(of: slot.videoBookmarkData) { resolveVideoName() }
    }

    private func resolveVideoName() {
        guard let data = slot.videoBookmarkData else {
            videoName = nil
            return
        }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            videoName = url.lastPathComponent
        } else {
            videoName = "Invalid"
        }
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
    static func segments(for slot: ScheduleSlot) -> [(start: Int, end: Int)] {
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
