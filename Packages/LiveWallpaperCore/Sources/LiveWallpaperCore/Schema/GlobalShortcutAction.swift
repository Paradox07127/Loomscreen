import Foundation
import AppKit
import SwiftUI

/// Identifies a global shortcut command. Adding a case requires:
/// 1) extending `default(for:)` with a sensible default binding (or `nil`),
/// 2) implementing the dispatcher in `GlobalShortcutManager.handle(_:)`.
public enum GlobalShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case togglePlayback
    case nextWallpaper
    case previousWallpaper
    case toggleMute
    case toggleMouseInteraction
    case toggleWallpapers
    case reloadWallpapers

    public var id: String { rawValue }

    /// `String` alias used as the `GlobalSettings.globalShortcuts` dictionary
    /// key. Decoupled from `RawValue` so a future case rename can keep the
    /// wire format stable through a `CodingKey`-style override.
    public typealias RawAction = String

    public var rawAction: RawAction { rawValue }

    public var displayNameKey: LocalizedStringKey {
        switch self {
        case .togglePlayback:
            return "Play / Pause All Wallpapers"
        case .nextWallpaper:
            return "Next Wallpaper (Active Display)"
        case .previousWallpaper:
            return "Previous Wallpaper (Active Display)"
        case .toggleMute:
            return "Toggle Mute"
        case .toggleMouseInteraction:
            return "Toggle Interaction"
        case .toggleWallpapers:
            return "Show / Hide All Wallpapers"
        case .reloadWallpapers:
            return "Reload All Wallpapers"
        }
    }

    public var displayName: String {
        switch self {
        case .togglePlayback:
            return AppLanguagePreference.localizedString("Play / Pause All Wallpapers")
        case .nextWallpaper:
            return AppLanguagePreference.localizedString("Next Wallpaper (Active Display)")
        case .previousWallpaper:
            return AppLanguagePreference.localizedString("Previous Wallpaper (Active Display)")
        case .toggleMute:
            return AppLanguagePreference.localizedString("Toggle Mute")
        case .toggleMouseInteraction:
            return AppLanguagePreference.localizedString("Toggle Interaction")
        case .toggleWallpapers:
            return AppLanguagePreference.localizedString("Show / Hide All Wallpapers")
        case .reloadWallpapers:
            return AppLanguagePreference.localizedString("Reload All Wallpapers")
        }
    }

    public var displayDescriptionKey: LocalizedStringKey {
        switch self {
        case .togglePlayback:
            return "Pause every active wallpaper, or resume them all."
        case .nextWallpaper:
            return "Advance the playlist on the display under the cursor."
        case .previousWallpaper:
            return "Step the playlist back on the display under the cursor."
        case .toggleMute:
            return "Mute or unmute video and scene wallpapers."
        case .toggleMouseInteraction:
            return "Turn pointer and click input on or off for scene and web wallpapers."
        case .toggleWallpapers:
            return "Hide every wallpaper to reveal the desktop, or bring them back."
        case .reloadWallpapers:
            return "Force every display to re-render its wallpaper."
        }
    }

    /// Default binding shipped on first launch.
    public static func defaultBinding(for action: GlobalShortcutAction) -> GlobalShortcutBinding? {
        switch action {
        case .togglePlayback:
            return GlobalShortcutBinding(keyCode: 49, modifiers: [.control, .shift])
        case .nextWallpaper:
            return GlobalShortcutBinding(keyCode: 124, modifiers: [.control, .shift])
        case .previousWallpaper:
            return GlobalShortcutBinding(keyCode: 123, modifiers: [.control, .shift])
        case .toggleMute:
            return GlobalShortcutBinding(keyCode: 46, modifiers: [.control, .shift])
        case .toggleMouseInteraction:
            return GlobalShortcutBinding(keyCode: 34, modifiers: [.control, .shift])
        case .toggleWallpapers:
            return GlobalShortcutBinding(keyCode: 4, modifiers: [.control, .shift])
        case .reloadWallpapers:
            return GlobalShortcutBinding(keyCode: 15, modifiers: [.control, .shift])
        }
    }
}

/// Hardware-level key combination — `keyCode` matches Carbon virtual key
/// codes (same space as `NSEvent.keyCode`), `modifiers` are
/// platform-independent flags that map to Carbon's `cmdKey` / `optionKey` /
/// etc. inside `GlobalShortcutManager`.
public struct GlobalShortcutBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: ModifierSet

    public init(keyCode: UInt32, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let command  = ModifierSet(rawValue: 1 << 0)
        public static let option   = ModifierSet(rawValue: 1 << 1)
        public static let control  = ModifierSet(rawValue: 1 << 2)
        public static let shift    = ModifierSet(rawValue: 1 << 3)
    }

    /// Human-readable form, e.g. `⌃⇧Space`. Used by both the settings
    /// capture view and accessibility descriptions.
    public var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option)  { symbols += "⌥" }
        if modifiers.contains(.shift)   { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + GlobalShortcutBinding.keyName(for: keyCode)
    }

    /// Falls back to `Key \(code)` for unmapped codes so debug rendering still works.
    public static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            if let scalar = printableCharacter(for: keyCode) {
                return String(scalar).uppercased()
            }
            return AppLanguagePreference.localizedFormat("Key %u", keyCode)
        }
    }

    private static func printableCharacter(for keyCode: UInt32) -> Character? {
        let map: [UInt32: Character] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
            8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
            16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
            38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "n", 46: "m", 47: "."
        ]
        return map[keyCode]
    }
}
