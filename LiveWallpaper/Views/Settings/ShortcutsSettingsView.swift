import SwiftUI
import AppKit

/// Lists every `GlobalShortcutAction` with a capture button so the user can
/// rebind, clear, or reset to default. Persists into
/// `GlobalSettings.globalShortcuts`; broadcast via
/// `.globalShortcutsDidChange` so `GlobalShortcutManager` re-registers.
struct ShortcutsSettingsView: View {
    @State private var bindings: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:]
    @State private var rejectionMessage: String?

    init() {
        _bindings = State(initialValue: SettingsManager.shared.loadGlobalSettings().globalShortcuts)
    }

    var body: some View {
        Form {
            Section {
                ForEach(GlobalShortcutAction.allCases) { action in
                    ShortcutRow(
                        action: action,
                        binding: bindingFor(action),
                        onCapture: { newBinding in updateBinding(newBinding, for: action) },
                        onClear: { updateBinding(nil, for: action) },
                        onReset: { resetToDefault(action) }
                    )
                }
                if let rejectionMessage {
                    Text(rejectionMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityLabel(Text("Shortcut rejected: \(rejectionMessage)"))
                }
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("These shortcuts work even when LiveWallpaper is in the background. Bare keys without a modifier are rejected (they would steal regular typing), and two actions can't share the same combination. Conflicts with system or other-app shortcuts will silently take whichever app registers first — pick a different combination if a shortcut doesn't trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 400)
    }

    private func bindingFor(_ action: GlobalShortcutAction) -> GlobalShortcutBinding? {
        if bindings.keys.contains(action.rawAction) {
            return bindings[action.rawAction] ?? nil
        }
        return GlobalShortcutAction.defaultBinding(for: action)
    }

    private func updateBinding(_ newBinding: GlobalShortcutBinding?, for action: GlobalShortcutAction) {
        if let newBinding {
            switch validate(newBinding, for: action) {
            case .valid:
                rejectionMessage = nil
            case .missingModifier:
                rejectionMessage = "Add at least one modifier (⌃ ⌥ ⇧ ⌘) — bare keys would intercept normal typing."
                NSSound.beep()
                return
            case .duplicate(let other):
                rejectionMessage = "\(newBinding.displayString) is already used by \(other.displayName)."
                NSSound.beep()
                return
            }
        } else {
            rejectionMessage = nil
        }
        bindings[action.rawAction] = newBinding
        persistBindings()
    }

    private func resetToDefault(_ action: GlobalShortcutAction) {
        rejectionMessage = nil
        bindings.removeValue(forKey: action.rawAction)
        persistBindings()
    }

    private func persistBindings() {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalShortcuts = bindings
        SettingsManager.shared.saveGlobalSettings(settings)
        NotificationCenter.default.post(name: .globalShortcutsDidChange, object: nil)
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
    let onCapture: (GlobalShortcutBinding) -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    @State private var isCapturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(action.displayDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ShortcutCaptureField(
                    binding: binding,
                    isCapturing: $isCapturing,
                    onCapture: onCapture
                )
                .frame(width: 140)

                Menu {
                    Button("Clear") { onClear() }
                    Button("Reset to Default") { onReset() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(Text("More options for \(action.displayName)"))
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
                    Text(binding.displayString)
                        .font(.system(size: 12, design: .monospaced))
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
            ? "Press keys to set shortcut"
            : (binding?.displayString ?? "No shortcut set"))
        .accessibilityHint(isCapturing
            ? "Listening for the next key combination"
            : "Click to record a new keyboard shortcut")
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
                // Ignore standalone modifier presses; require at least one
                // non-modifier key.
                let keyCode = UInt32(event.keyCode)
                let modifiers = self.modifierSet(from: event.modifierFlags)
                let binding = GlobalShortcutBinding(keyCode: keyCode, modifiers: modifiers)
                self.onCapture(binding)
                deactivate()
                // Swallow the event so the captured combo doesn't leak into
                // whatever text field has focus.
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
