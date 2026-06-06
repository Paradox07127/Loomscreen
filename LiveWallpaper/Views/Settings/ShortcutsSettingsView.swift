import SwiftUI
import AppKit

/// Lists every `GlobalShortcutAction` with a capture button so the user can
/// rebind, clear, or reset to default. Persists into
/// `GlobalSettings.globalShortcuts`; broadcast via
/// `.globalShortcutsDidChange` so `GlobalShortcutManager` re-registers.
struct ShortcutsSettingsView: View {
    @State private var bindings: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:]
    @State private var rejectionMessage: String?
    @State private var globalShortcutsEnabled: Bool

    init() {
        let settings = SettingsManager.shared.loadGlobalSettings()
        _bindings = State(initialValue: settings.globalShortcuts)
        _globalShortcutsEnabled = State(initialValue: settings.globalShortcutsEnabled)
    }

    var body: some View {
        Form {
            masterEnableSection

            Section {
                ForEach(GlobalShortcutAction.allCases) { action in
                    ShortcutRow(
                        action: action,
                        binding: bindingFor(action),
                        isEnabled: globalShortcutsEnabled,
                        onCapture: { newBinding in updateBinding(newBinding, for: action) },
                        onClear: { updateBinding(nil, for: action) },
                        onReset: { resetToDefault(action) }
                    )
                }
                if let rejectionMessage {
                    Text(verbatim: rejectionMessage)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                        .accessibilityLabel(Text("Shortcut rejected: \(rejectionMessage)"))
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                shortcutFooter
            }
            .disabled(!globalShortcutsEnabled)
        }
        .settingsFormChrome(minWidth: 500, minHeight: 400)
        .onReceive(NotificationCenter.default.publisher(for: .globalShortcutsDidChange)) { _ in
            // Pick up reset / import side-effects fired from elsewhere in
            // the app so neither the toggle nor the row bindings get
            // overwritten by a stale local @State on the next save.
            let latest = SettingsManager.shared.loadGlobalSettings()
            var didResync = false
            if globalShortcutsEnabled != latest.globalShortcutsEnabled {
                globalShortcutsEnabled = latest.globalShortcutsEnabled
                didResync = true
            }
            if bindings != latest.globalShortcuts {
                bindings = latest.globalShortcuts
                didResync = true
            }
            if didResync { rejectionMessage = nil }
        }
    }

    /// Single-line toggle row. The explanation lives in the section
    /// footer rather than repeating itself as a subtitle inside the row.
    private var masterEnableSection: some View {
        Section {
            Toggle("Enable Global Shortcuts", isOn: masterEnableBinding)
                .toggleStyle(.switch)
                .accessibilityHint(Text("Master switch for every global shortcut. Bindings are preserved while off."))
        }
    }

    /// Identity-set guarded binding so a noisy reconcile pass cannot fire
    /// `persistSettings` repeatedly (CLAUDE.md §8).
    private var masterEnableBinding: Binding<Bool> {
        Binding(
            get: { globalShortcutsEnabled },
            set: { newValue in
                guard globalShortcutsEnabled != newValue else { return }
                globalShortcutsEnabled = newValue
                rejectionMessage = nil
                persistSettings()
            }
        )
    }

    /// Compact bullet list replaces the original long-paragraph footer so
    /// each rule scans independently. Symbols are leading icons rather than
    /// inline emoji so the type styling stays consistent across the row.
    private var shortcutFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            shortcutFooterRow(systemImage: "moon.circle", text: "Works even when LiveWallpaper is in the background.")
            shortcutFooterRow(systemImage: "command", text: "Must include at least one modifier (⌃ ⌥ ⇧ ⌘).")
            shortcutFooterRow(systemImage: "arrow.left.arrow.right", text: "Two actions can't share the same combination.")
            shortcutFooterRow(systemImage: "exclamationmark.triangle", text: "If a system or other-app shortcut wins, pick a different combination.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func shortcutFooterRow(systemImage: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .frame(width: 14, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bindingFor(_ action: GlobalShortcutAction) -> GlobalShortcutBinding? {
        if bindings.keys.contains(action.rawAction) {
            return bindings[action.rawAction] ?? nil
        }
        return GlobalShortcutAction.defaultBinding(for: action)
    }

    private func updateBinding(_ newBinding: GlobalShortcutBinding?, for action: GlobalShortcutAction) {
        // If the master switch flipped off mid-capture, drop the result
        // rather than persisting a binding the user can no longer trigger.
        guard globalShortcutsEnabled else { return }
        if let newBinding {
            switch validate(newBinding, for: action) {
            case .valid:
                rejectionMessage = nil
            case .missingModifier:
                rejectionMessage = String(localized: "Add at least one modifier (⌃ ⌥ ⇧ ⌘) — bare keys would intercept normal typing.", defaultValue: "Add at least one modifier (⌃ ⌥ ⇧ ⌘) — bare keys would intercept normal typing.", comment: "Shortcut validation rejection message.")
                NSSound.beep()
                return
            case .duplicate(let other):
                rejectionMessage = String(localized: "\(newBinding.displayString) is already used by \(other.displayName).", comment: "Shortcut duplicate rejection message. Placeholders are shortcut and action name.")
                NSSound.beep()
                return
            }
        } else {
            rejectionMessage = nil
        }
        bindings[action.rawAction] = newBinding
        persistSettings()
    }

    private func resetToDefault(_ action: GlobalShortcutAction) {
        rejectionMessage = nil
        bindings.removeValue(forKey: action.rawAction)
        persistSettings()
    }

    /// Writes the bindings dictionary AND the master enable flag in a
    /// single save so a toggle flip can never race with a binding edit.
    /// `GlobalShortcutManager` re-evaluates both on
    /// `.globalShortcutsDidChange`.
    private func persistSettings() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalShortcuts = bindings
        settings.globalShortcutsEnabled = globalShortcutsEnabled
        SettingsManager.shared.saveGlobalSettings(settings)
        Task { @MainActor in
            NotificationCenter.default.post(name: .globalShortcutsDidChange, object: nil)
        }
    }

    private func validate(_ binding: GlobalShortcutBinding, for action: GlobalShortcutAction) -> ValidationResult {
        guard !binding.modifiers.isEmpty else { return .missingModifier }
        for other in GlobalShortcutAction.allCases where other != action {
            if bindingFor(other) == binding { return .duplicate(other) }
        }
        return .valid
    }

    private enum ValidationResult {
        case valid
        case missingModifier
        case duplicate(GlobalShortcutAction)
    }
}

private struct ShortcutRow: View {
    let action: GlobalShortcutAction
    let binding: GlobalShortcutBinding?
    /// Driven by the master enable toggle. When false the capture field
    /// and per-row menu are dimmed and unclickable, but the row stays
    /// visible so the user sees their saved combinations.
    let isEnabled: Bool
    let onCapture: (GlobalShortcutBinding) -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    @State private var isCapturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: action.displayName)
                        .font(DesignTokens.Typography.body)
                    Text(verbatim: action.displayDescription)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ShortcutCaptureField(
                    binding: binding,
                    isCapturing: $isCapturing,
                    onCapture: onCapture
                )
                .frame(width: 140)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
                .onChange(of: isEnabled) { _, enabled in
                    // If the master switch flips off mid-capture, drop
                    // the listener so we don't trap the next key event.
                    if !enabled { isCapturing = false }
                }

                Menu {
                    Button("Clear", role: .destructive) { onClear() }
                    Button("Reset to Default", role: .destructive) { onReset() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
                .accessibilityLabel(Text("More options for \(action.displayName)", comment: "Shortcut row menu a11y label. The placeholder is the shortcut action name."))
            }
        }
        .padding(.vertical, 4)
    }
}

/// A small click-to-capture field. When tapped, it switches into capture
/// mode and listens for the next key-down via a local NSEvent monitor —
/// same approach Apple uses in System Settings → Keyboard → Shortcuts.
private struct ShortcutCaptureField: View {
    let binding: GlobalShortcutBinding?
    @Binding var isCapturing: Bool
    let onCapture: (GlobalShortcutBinding) -> Void

    var body: some View {
        Button(action: { isCapturing.toggle() }) {
            HStack {
                if isCapturing {
                    Text("Press keys…")
                        .foregroundStyle(.secondary)
                        .italic()
                } else if let binding {
                    Text(verbatim: binding.displayString)
                        .font(DesignTokens.Typography.code)
                } else {
                    Text("None")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isCapturing ? Color.accentColor.opacity(0.18) : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isCapturing ? Color.accentColor : Color.primary.opacity(0.10),
                        lineWidth: isCapturing ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .background(KeyCaptureMonitor(isActive: $isCapturing) { binding in
            onCapture(binding)
        })
        .accessibilityLabel(isCapturing
            ? Text("Press keys to set shortcut")
            : shortcutAccessibilityLabel)
        .accessibilityHint(isCapturing
            ? Text("Listening for the next key combination")
            : Text("Click to record a new keyboard shortcut"))
    }

    private var shortcutAccessibilityLabel: Text {
        if let binding {
            return Text(verbatim: binding.displayString)
        }
        return Text("No shortcut set")
    }
}

/// Hidden NSView that runs a local key-down monitor for the duration of
/// `isActive == true`. SwiftUI cannot trap raw key codes + modifier flags
/// without dropping into AppKit — `onKeyPress` only sees the resolved
/// character string, which loses the keycode we need for Carbon.
private struct KeyCaptureMonitor: NSViewRepresentable {
    @Binding var isActive: Bool
    let onCapture: (GlobalShortcutBinding) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isActive {
            context.coordinator.startMonitoring(deactivate: { isActive = false })
        } else {
            context.coordinator.stopMonitoring()
        }
    }

    @MainActor
    final class Coordinator {
        let onCapture: (GlobalShortcutBinding) -> Void
        nonisolated(unsafe) private var localMonitor: Any?

        init(onCapture: @escaping (GlobalShortcutBinding) -> Void) {
            self.onCapture = onCapture
        }

        deinit {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func startMonitoring(deactivate: @escaping () -> Void) {
            stopMonitoring()
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let keyCode = UInt32(event.keyCode)
                let modifiers = self.modifierSet(from: event.modifierFlags)
                let binding = GlobalShortcutBinding(keyCode: keyCode, modifiers: modifiers)
                self.onCapture(binding)
                deactivate()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }

        private func modifierSet(from flags: NSEvent.ModifierFlags) -> GlobalShortcutBinding.ModifierSet {
            var set: GlobalShortcutBinding.ModifierSet = []
            if flags.contains(.command)  { set.insert(.command) }
            if flags.contains(.option)   { set.insert(.option) }
            if flags.contains(.control)  { set.insert(.control) }
            if flags.contains(.shift)    { set.insert(.shift) }
            return set
        }
    }
}
