import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LiveWallpaperSharedUI

/// Time-of-day wallpaper scheduling UI with conflict detection + per-slot
/// add/remove. Slots can span midnight.
struct ScheduleSection: View {
    @Binding var scheduleSlots: [ScheduleSlot]
    var screen: Screen
    var screenManager: ScreenManager

    @State private var currentHour: Int = Calendar.current.component(.hour, from: Date())
    /// Slot IDs to flash with red outline when a stepper change conflicts.
    @State private var conflictHighlight: Set<UUID> = []
    @State private var addSlotErrorMessage: String?
    @State private var conflictMessage: String?
    @State private var pendingDestructive: PendingDestructive?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let timelinePalette: [Color] = [.blue, .orange, .green, .purple]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if scheduleSlots.isEmpty {
                emptyState
            } else {
                ScheduleTimelineBar(
                    slots: scheduleSlots,
                    currentHour: currentHour,
                    palette: Self.timelinePalette
                )

                VStack(spacing: 6) {
                    ForEach(Array($scheduleSlots.enumerated()), id: \.element.id) { index, $slot in
                        ScheduleSlotRow(
                            slot: $slot,
                            accent: Self.timelinePalette[index % Self.timelinePalette.count],
                            isActive: slot.containsHour(currentHour),
                            isHighlightedConflict: conflictHighlight.contains(slot.id),
                            videoNameProvider: { screenManager.bookmarkDisplayName(for: $0) },
                            onVideoSelect: { selectVideo(for: slot.id) },
                            onClearVideo: { clearVideo(for: slot.id) },
                            onRemove: { removeSlot(slot.id) },
                            onValidateChange: { proposedStart, proposedEnd in
                                validateAndCommit(slotID: slot.id, start: proposedStart, end: proposedEnd)
                            }
                        )
                    }
                }

                if let message = addSlotErrorMessage ?? conflictMessage {
                    conflictBanner(message: message)
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

                    Button(role: .destructive, action: disableSchedule) {
                        Text("Disable Schedule")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .accessibilityLabel(Text("Disable schedule"))
                    .accessibilityHint(Text("Removes all schedule slots and returns to normal playback"))
                }
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
            // Drop stale conflict UI when slots are added/removed/re-ordered.
            if !conflictHighlight.isEmpty || conflictMessage != nil {
                conflictHighlight.removeAll()
                conflictMessage = nil
            }
        }
        .onChange(of: screen.id) { _, _ in
            // Different screen → fresh state.
            conflictHighlight.removeAll()
            conflictMessage = nil
            addSlotErrorMessage = nil
        }
        .confirmDestructive($pendingDestructive)
    }

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

    @ViewBuilder
    private func conflictBanner(message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(verbatim: message)
                .font(.system(size: 11))
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

    // MARK: - Actions

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

    private func selectVideo(for slotID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.prompt = L10n.Panel.setVideo
        let assign: ([URL]) -> Void = { urls in
            assignVideo(urls: urls, to: slotID)
        }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: parent) { response in
                guard response == .OK else { return }
                assign(panel.urls)
            }
        } else {
            guard panel.runModal() == .OK else { return }
            assign(panel.urls)
        }
    }

    private func assignVideo(urls: [URL], to slotID: UUID) {
        guard let url = urls.first else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        guard let bookmark = ResourceUtilities.createVideoBookmark(for: url),
              let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
        screenManager.recordBookmarkDisplayName(bookmark, name: url.lastPathComponent)
        scheduleSlots[index].videoBookmarkData = bookmark
        screenManager.updateScheduleSlots(scheduleSlots, for: screen)
    }

    /// Validate a candidate stepper change against other slots; commit if no
    /// conflict, otherwise reject and flash a red outline + persistent message.
    /// Zero-length proposals (start == end) are silently rejected.
    private func validateAndCommit(slotID: UUID, start: Int, end: Int) {
        guard let index = scheduleSlots.firstIndex(where: { $0.id == slotID }) else { return }
        let normStart = ((start % 24) + 24) % 24
        let normEnd = ((end % 24) + 24) % 24
        guard normStart != normEnd else {
            // Reject zero-length silently — stepper just doesn't advance.
            return
        }
        var probe = scheduleSlots[index]
        probe.startHour = normStart
        probe.endHour = normEnd
        let others = scheduleSlots.filter { $0.id != slotID }
        let conflicts = SchedulePolicy.conflicts(slot: probe, against: others)
        if conflicts.isEmpty {
            scheduleSlots[index].startHour = normStart
            scheduleSlots[index].endHour = normEnd
            screenManager.updateScheduleSlots(scheduleSlots, for: screen)
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) { conflictMessage = nil }
            return
        }
        let conflictingLabels = scheduleSlots
            .filter { conflicts.contains($0.id) }
            .map(\.localizedLabel)
            .joined(separator: ", ")
        let format = String(
            localized: "Time range overlaps with %@",
            defaultValue: "Time range overlaps with %@",
            comment: "Schedule conflict message; placeholder is a comma-separated list of overlapping slot labels."
        )
        let formatted = String(format: format, conflictingLabels)
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            conflictMessage = formatted
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
        if scheduleSlots.count <= 1 {
            let slotCount = scheduleSlots.count
            pendingDestructive = PendingDestructive(.disableSchedule(slotCount: slotCount)) {
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

    private func addSlot() {
        guard let free = SchedulePolicy.findFreeRange(in: scheduleSlots, minHours: 2) else {
            let message = String(
                localized: "No free time range. Adjust an existing slot first.",
                defaultValue: "No free time range. Adjust an existing slot first.",
                comment: "Schedule error shown when Add Slot cannot find a gap of at least 2 hours."
            )
            withAnimation { addSlotErrorMessage = message }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation { addSlotErrorMessage = nil }
            }
            return
        }
        let label = defaultLabel(for: free.start)
        let newSlot = ScheduleSlot(
            startHour: free.start % 24,
            endHour: free.end % 24,
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
    let accent: Color
    let isActive: Bool
    let isHighlightedConflict: Bool
    let videoNameProvider: (Data) -> String?
    let onVideoSelect: () -> Void
    let onClearVideo: () -> Void
    let onRemove: () -> Void
    /// Called on stepper change with candidate start/end. Parent validates and
    /// writes back to the binding only on success.
    let onValidateChange: (_ start: Int, _ end: Int) -> Void

    @State private var videoName: String?
    @State private var isHovering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            timeRow
            videoRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .animation(.snappy(duration: 0.2), value: isHighlightedConflict)
        .onHover { isHovering = $0 }
        .onAppear { resolveVideoName() }
        .onChange(of: slot.videoBookmarkData) { resolveVideoName() }
    }

    // MARK: Subviews

    @ViewBuilder
    private var timeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(isActive ? accent : Color.secondary.opacity(0.35))
                .symbolEffect(.pulse, options: .continuouslyRepeating, isActive: isActive)
                .accessibilityHidden(true)

            Text(verbatim: slot.localizedLabel)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)

            Stepper(
                value: Binding(
                    get: { slot.startHour },
                    set: { onValidateChange($0, slot.endHour) }
                ),
                in: 0...23
            ) {
                Text(verbatim: formatHour(slot.startHour))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .accessibilityLabel(Text("Start hour for \(slot.localizedLabel)", comment: "A11y label for a schedule slot start-hour stepper. The placeholder is the slot label."))
            .accessibilityValue(Text(verbatim: formatHour(slot.startHour)))

            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Stepper(
                value: Binding(
                    get: { slot.endHour },
                    set: { onValidateChange(slot.startHour, $0) }
                ),
                in: 0...23
            ) {
                Text(verbatim: formatHour(slot.endHour))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .accessibilityLabel(Text("End hour for \(slot.localizedLabel)", comment: "A11y label for a schedule slot end-hour stepper. The placeholder is the slot label."))
            .accessibilityValue(Text(verbatim: formatHour(slot.endHour)))

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .destructiveControlTint()
            .opacity(isHovering ? 1 : 0)
            .accessibilityHidden(!isHovering)
            .accessibilityLabel(Text("Remove \(slot.localizedLabel) slot", comment: "A11y label for removing a schedule slot. The placeholder is the slot label."))
        }
    }

    @ViewBuilder
    private var videoRow: some View {
        HStack(spacing: 8) {
            videoThumbnail
            if let name = videoName {
                Text(verbatim: name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(action: onClearVideo) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .destructiveControlTint()
                .opacity(isHovering ? 1 : 0)
                .accessibilityHidden(!isHovering)
                .accessibilityLabel(Text("Clear video for \(slot.localizedLabel)", comment: "A11y label for clearing a video from a schedule slot. The placeholder is the slot label."))
            } else {
                Button(action: onVideoSelect) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 10))
                        Text("Set Video")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Set video for \(slot.localizedLabel)", comment: "A11y label for setting a video on a schedule slot. The placeholder is the slot label."))
                .accessibilityHint(Text("Choose a video for this schedule slot"))
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 15)
    }

    @ViewBuilder
    private var videoThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.55), accent.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: videoName != nil ? "film.fill" : "film")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(videoName != nil ? 0.95 : 0.5))
        }
        .frame(width: 22, height: 14)
        .accessibilityHidden(true)
    }

    private var rowBackground: Color {
        if isHighlightedConflict { return Color.red.opacity(0.07) }
        if isHovering { return Color.primary.opacity(0.04) }
        return Color.primary.opacity(0.025)
    }

    private var borderColor: Color {
        if isHighlightedConflict { return Color.red.opacity(0.75) }
        return Color.primary.opacity(0.06)
    }

    private func resolveVideoName() {
        guard let data = slot.videoBookmarkData else {
            videoName = nil
            return
        }
        videoName = videoNameProvider(data) ?? "Invalid"
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
    let palette: [Color]

    private let majorHours: [Int] = [0, 6, 12, 18, 24]

    /// Splits midnight-wrapping slots into timeline segments.
    nonisolated static func segments(for slot: ScheduleSlot) -> [(start: Int, end: Int, wraps: Bool)] {
        if slot.startHour == slot.endHour {
            return []
        }
        if slot.startHour < slot.endHour {
            return [(slot.startHour, slot.endHour, false)]
        }
        return [(slot.startHour, 24, true), (0, slot.endHour, true)]
    }

    private var activeSlotLabel: String {
        if let active = slots.first(where: { $0.containsHour(currentHour) }) {
            return active.localizedLabel
        }
        return "no active slot"
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    background

                    minorTicks(width: width)
                    majorTicks(width: width)

                    slotSegments(width: width)

                    cursor(width: width)
                }
            }
            .frame(height: 26)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))

            hourLabels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Schedule timeline, \(slots.count) slots, currently \(currentHour):00, active slot: \(activeSlotLabel)"))
    }

    @ViewBuilder
    private var background: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
            .fill(Color.primary.opacity(0.06))
    }

    @ViewBuilder
    private func minorTicks(width: CGFloat) -> some View {
        ForEach(0..<25, id: \.self) { hour in
            if !majorHours.contains(hour) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 0.5, height: 6)
                    .offset(x: CGFloat(hour) / 24.0 * width, y: 0)
            }
        }
    }

    @ViewBuilder
    private func majorTicks(width: CGFloat) -> some View {
        ForEach(majorHours, id: \.self) { hour in
            Rectangle()
                .fill(Color.primary.opacity(0.28))
                .frame(width: 0.5, height: 12)
                .offset(x: CGFloat(hour) / 24.0 * width, y: 0)
        }
    }

    @ViewBuilder
    private func slotSegments(width: CGFloat) -> some View {
        ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
            let segments = Self.segments(for: slot)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                let startFraction = CGFloat(segment.start) / 24.0
                let endFraction = CGFloat(segment.end) / 24.0
                let segmentWidth = max(0, (endFraction - startFraction) * width)
                if segmentWidth > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(palette[index % palette.count].opacity(segment.wraps ? 0.55 : 0.65))
                        .frame(width: segmentWidth, height: 10)
                        .offset(x: startFraction * width, y: 14)
                }
            }
        }
    }

    @ViewBuilder
    private func cursor(width: CGFloat) -> some View {
        let markerX = CGFloat(currentHour) / 24.0 * width
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 22)
            .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
            .offset(x: markerX - 1, y: 2)
    }

    @ViewBuilder
    private var hourLabels: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ForEach(majorHours, id: \.self) { hour in
                let fraction = CGFloat(hour) / 24.0
                let alignment: HorizontalAlignment = (hour == 0) ? .leading : (hour == 24 ? .trailing : .center)
                Text(verbatim: hourLabel(hour))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
                    .offset(
                        x: fraction * width - (alignment == .leading ? 0 : (alignment == .trailing ? 30 : 15)),
                        y: 0
                    )
            }
        }
        .frame(height: 12)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12A"
        case 12: return "12P"
        case 24: return "12A"
        default: return hour < 12 ? "\(hour)A" : "\(hour - 12)P"
        }
    }
}
