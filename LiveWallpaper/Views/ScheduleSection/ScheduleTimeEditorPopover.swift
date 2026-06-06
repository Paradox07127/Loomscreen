import SwiftUI
import LiveWallpaperCore
import LiveWallpaperSharedUI

/// Popover anchored to a slot row's time-range label. Replaces the two
/// inline `Stepper`s with wrap-aware `Menu` pickers and surfaces
/// conflicts before commit.
///
/// Draft state is held locally — the row only learns about the change
/// when the user presses **Apply**, so a noisy in-progress selection
/// can't repeatedly fight `SchedulePolicy.conflicts` and emit spurious
/// banners on the parent.
struct ScheduleTimeEditorPopover: View {
    let slotID: UUID
    let initialStart: Int
    let initialEnd: Int
    let otherSlots: [ScheduleSlot]
    let onCommit: (_ start: Int, _ end: Int) -> Void
    let onCancel: () -> Void

    @State private var draftStart: Int
    @State private var draftEnd: Int

    init(
        slotID: UUID,
        initialStart: Int,
        initialEnd: Int,
        otherSlots: [ScheduleSlot],
        onCommit: @escaping (Int, Int) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.slotID = slotID
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.otherSlots = otherSlots
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draftStart = State(initialValue: initialStart)
        _draftEnd = State(initialValue: initialEnd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Time Range")
                .font(DesignTokens.Typography.bodyEmphasized)

            VStack(spacing: 8) {
                pickerRow(
                    label: Text("From", comment: "Schedule time editor: start-time label."),
                    selection: $draftStart,
                    accessibilityLabel: Text("Start hour"),
                    labelFor: { ScheduleTimeFormatter.hourLabel($0) },
                    disabledHour: { _ in false }
                )
                pickerRow(
                    label: Text("To", comment: "Schedule time editor: end-time label."),
                    selection: $draftEnd,
                    accessibilityLabel: Text("End hour"),
                    labelFor: { ScheduleTimeFormatter.endHourMenuLabel(end: $0, start: draftStart) },
                    disabledHour: { hour in hour == draftStart }
                )
            }

            if let banner = conflictBanner {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isZeroLength {
                Label("Start and end times must differ.", systemImage: "exclamationmark.circle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(role: .cancel) {
                    onCancel()
                } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onCommit(draftStart, draftEnd)
                } label: {
                    Text("Apply")
                        .frame(minWidth: 60)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(applyDisabled)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func pickerRow(
        label: Text,
        selection: Binding<Int>,
        accessibilityLabel: Text,
        labelFor: @escaping (Int) -> String,
        disabledHour: @escaping (Int) -> Bool
    ) -> some View {
        HStack {
            label
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Spacer()
            Menu(labelFor(selection.wrappedValue)) {
                ForEach(0..<24, id: \.self) { hour in
                    Button {
                        selection.wrappedValue = hour
                    } label: {
                        Text(verbatim: labelFor(hour))
                    }
                    .disabled(disabledHour(hour))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(Text(verbatim: labelFor(selection.wrappedValue)))
        }
    }

    // MARK: - Validation

    private var isZeroLength: Bool {
        draftStart == draftEnd
    }

    private var conflictingSlots: [ScheduleSlot] {
        guard !isZeroLength else { return [] }
        let probe = ScheduleSlot(
            id: slotID,
            startHour: draftStart,
            endHour: draftEnd,
            label: "probe"
        )
        let ids = SchedulePolicy.conflicts(slot: probe, against: otherSlots)
        return otherSlots.filter { ids.contains($0.id) }
    }

    private var conflictBanner: String? {
        let conflicts = conflictingSlots
        guard !conflicts.isEmpty else { return nil }
        let names = conflicts.map(\.localizedLabel).joined(separator: ", ")
        let format = String(
            localized: "Overlaps with %@",
            defaultValue: "Overlaps with %@",
            comment: "Schedule editor warning when the chosen range overlaps an existing slot. Placeholder is a comma-separated list of slot labels."
        )
        return String(format: format, names)
    }

    private var applyDisabled: Bool {
        if isZeroLength { return true }
        if !conflictingSlots.isEmpty { return true }
        if draftStart == initialStart && draftEnd == initialEnd { return true }
        return false
    }
}
