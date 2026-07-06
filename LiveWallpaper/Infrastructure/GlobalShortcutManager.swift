import Foundation
import AppKit
import Carbon.HIToolbox

/// Wires user-configurable global hot keys (registered via Carbon's
/// `RegisterEventHotKey`) to their corresponding `ScreenManager` actions.
///
/// Why Carbon — `NSEvent.addGlobalMonitorForEvents` requires the
/// Accessibility permission, while `RegisterEventHotKey` works inside the
/// app sandbox without prompting. Carbon's HotKey Manager is still
/// supported on macOS 26 / Tahoe even though most of Carbon is gone.
@MainActor
final class GlobalShortcutManager {
    private weak var screenManager: ScreenManager?
    /// Mutated only on MainActor; `nonisolated(unsafe)` so deinit can clean
    /// up Carbon refs without crossing actor boundaries.
    nonisolated(unsafe) private var registrations: [GlobalShortcutAction: HotKeyRegistration] = [:]
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    nonisolated(unsafe) private var preferenceObserver: NSObjectProtocol?

    init(screenManager: ScreenManager) {
        self.screenManager = screenManager
    }

    deinit {
        cleanupCarbonState()
    }

    func start() {
        guard installEventHandlerIfNeeded() else { return }
        registerFromPreferences()
        observePreferenceChanges()
    }

    func stop() {
        cleanupCarbonState()
    }

    // MARK: - Registration

    private func registerFromPreferences() {
        unregisterAll()

        let settings = SettingsManager.shared.loadGlobalSettings()
        guard settings.globalShortcutsEnabled else {
            // Master switch off: leave Carbon clean but keep the event handler
            // installed so we can re-register instantly when re-enabled.
            return
        }

        let overrides = settings.globalShortcuts
        for action in GlobalShortcutAction.allCases {
            let binding: GlobalShortcutBinding?
            if overrides.keys.contains(action.rawAction) {
                binding = overrides[action.rawAction] ?? nil
            } else {
                binding = GlobalShortcutAction.defaultBinding(for: action)
            }
            guard let binding else { continue }
            register(action: action, binding: binding)
        }
    }

    private func register(action: GlobalShortcutAction, binding: GlobalShortcutBinding) {
        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("LWLP"), id: UInt32(action.signatureID))
        var hotKeyRef: EventHotKeyRef?

        let modMask = carbonModifiers(for: binding.modifiers)
        let status = RegisterEventHotKey(
            binding.keyCode,
            modMask,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            Logger.warning("Failed to register hot key for \(action.rawValue): status=\(status)", category: .general)
            return
        }

        registrations[action] = HotKeyRegistration(ref: hotKeyRef, hotKeyID: hotKeyID)
    }

    private func unregisterAll() {
        for (_, registration) in registrations {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
    }

    private func observePreferenceChanges() {
        guard preferenceObserver == nil else { return }
        // `Task { @MainActor }` rather than `MainActor.assumeIsolated`: the
        // observer runs on the register-time queue, so we need the hop to honor
        // the @MainActor contract. Free here since registration is cold-path.
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .globalShortcutsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.registerFromPreferences()
            }
        }
    }

    /// Drops every Carbon resource and observer. Safe to call from a
    /// nonisolated deinit because every property it touches is
    /// `nonisolated(unsafe)`.
    nonisolated private func cleanupCarbonState() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()

        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }

        if let observer = preferenceObserver {
            NotificationCenter.default.removeObserver(observer)
            preferenceObserver = nil
        }
    }

    // MARK: - Event Handler

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef, let userData else { return noErr }
                var receivedID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )
                guard status == noErr else { return status }

                let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                let signatureID = Int(receivedID.id)
                Task { @MainActor in
                    manager.dispatchHotKey(signatureID: signatureID)
                }
                return noErr
            },
            1,
            &spec,
            userData,
            &eventHandler
        )

        guard status == noErr else {
            Logger.warning("Failed to install global hot-key event handler: status=\(status)", category: .general)
            eventHandler = nil
            return false
        }
        return true
    }

    private func dispatchHotKey(signatureID: Int) {
        guard let action = GlobalShortcutAction.action(forSignatureID: signatureID) else { return }
        // Swallow keys that arrive after the master switch was flipped off
        // between the Carbon press and this MainActor hop.
        guard SettingsManager.shared.loadGlobalSettings().globalShortcutsEnabled else { return }
        guard let manager = screenManager else { return }
        switch action {
        case .togglePlayback:
            manager.togglePlayback()
        case .nextWallpaper:
            let target = screenUnderCursor(in: manager) ?? manager.screens.first
            if let target { manager.advancePlaylist(for: target) }
        case .previousWallpaper:
            let target = screenUnderCursor(in: manager) ?? manager.screens.first
            if let target { manager.regressPlaylist(for: target) }
        case .toggleMute:
            toggleGlobalMute(via: manager)
        case .toggleMouseInteraction:
            toggleGlobalMouseInteraction(via: manager)
        case .toggleWallpapers:
            manager.setWallpapersEnabled(!manager.wallpapersGloballyEnabled)
        case .reloadWallpapers:
            manager.reloadAllScreens()
        }
    }

    /// Only video and scene wallpapers route audio, so the new mute state is
    /// decided from those alone — HTML/shader screens neither count toward the
    /// "any unmuted" check nor receive the toggle.
    private func toggleGlobalMute(via manager: ScreenManager) {
        let mutedStates: [Bool] = manager.screens.compactMap { screen in
            guard let config = manager.getConfiguration(for: screen) else { return nil }
            switch config.wallpaperType {
            case .video, .scene: return config.muted
            default: return nil
            }
        }
        guard !mutedStates.isEmpty else { return }
        let newMuted = mutedStates.contains(false)
        for screen in manager.screens {
            switch manager.getConfiguration(for: screen)?.wallpaperType {
            case .video, .scene: manager.updateMuted(newMuted, for: screen)
            default: break
            }
        }
    }

    /// "Mouse interaction" means cursor-follow for scenes, click-through for web
    /// wallpapers, and clickable dashboard for the monitor — the types with a
    /// mouse seam. The new on/off state is decided across just those screens,
    /// then pushed per type.
    private func toggleGlobalMouseInteraction(via manager: ScreenManager) {
        let states: [Bool] = manager.screens.compactMap { screen in
            guard let config = manager.getConfiguration(for: screen) else { return nil }
            switch config.wallpaperType {
            case .scene:   return config.sceneMouseInteractionEnabled
            case .html:    return config.htmlConfig?.allowMouseInteraction
            case .monitor: return config.activeWallpaper.monitorConfiguration?.mouseInteractionEnabled
            default:       return nil
            }
        }
        guard !states.isEmpty else { return }
        let newEnabled = !states.contains(true)
        for screen in manager.screens {
            guard let config = manager.getConfiguration(for: screen) else { continue }
            switch config.wallpaperType {
            case .scene:
                manager.updateSceneMouseInteraction(newEnabled, for: screen)
            case .html:
                if var html = config.htmlConfig {
                    html.allowMouseInteraction = newEnabled
                    manager.updateHTMLConfig(html, for: screen)
                }
            case .monitor:
                if var monitor = config.activeWallpaper.monitorConfiguration {
                    monitor.mouseInteractionEnabled = newEnabled
                    manager.updateMonitorConfiguration(monitor, for: screen)
                }
            default:
                break
            }
        }
    }

    private func screenUnderCursor(in manager: ScreenManager) -> Screen? {
        let mouseLocation = NSEvent.mouseLocation
        guard let nsScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else {
            return nil
        }
        return manager.screens.first { $0.id == screenIDFromNSScreen(nsScreen) }
    }

    /// `NSScreen` exposes the display ID through a private-ish key on its device description dict.
    private func screenIDFromNSScreen(_ screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    // MARK: - Modifier Translation

    private func carbonModifiers(for set: GlobalShortcutBinding.ModifierSet) -> UInt32 {
        var mask: UInt32 = 0
        if set.contains(.command) { mask |= UInt32(cmdKey) }
        if set.contains(.option)  { mask |= UInt32(optionKey) }
        if set.contains(.control) { mask |= UInt32(controlKey) }
        if set.contains(.shift)   { mask |= UInt32(shiftKey) }
        return mask
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        let bytes = string.utf8
        var result: FourCharCode = 0
        for byte in bytes.prefix(4) {
            result = (result << 8) | FourCharCode(byte)
        }
        return result
    }
}

private struct HotKeyRegistration {
    let ref: EventHotKeyRef
    let hotKeyID: EventHotKeyID
}

private extension GlobalShortcutAction {
    /// Stable numeric tag used inside Carbon `EventHotKeyID.id`. Mapping
    /// uses `allCases.firstIndex` rather than the raw string so the value
    /// stays a pure UInt32 — Carbon's struct can't carry a String.
    var signatureID: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 0
    }

    static func action(forSignatureID id: Int) -> GlobalShortcutAction? {
        let index = id - 1
        guard allCases.indices.contains(index) else { return nil }
        return allCases[index]
    }
}
