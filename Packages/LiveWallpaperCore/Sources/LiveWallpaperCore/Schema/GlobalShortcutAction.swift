import Foundation
import AppKit

/// Identifies a global shortcut command. Adding a case requires:
/// 1) extending `default(for:)` with a sensible default binding (or `nil`),
/// 2) implementing the dispatcher in `GlobalShortcutManager.handle(_:)`.
public enum GlobalShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case togglePlayback
    case nextWallpaper
    case toggleMute

    public var id: String { rawValue }

    /// `String` alias used as the `GlobalSettings.globalShortcuts` dictionary
    /// key. Decoupled from `RawValue` so a future case rename can keep the
    /// wire format stable through a `CodingKey`-style override.
    public typealias RawAction = String

    public var rawAction: RawAction { rawValue }

    public var displayName: String {
        switch self {
        case .togglePlayback:
            return String(localized: "Play / Pause All Wallpapers", defaultValue: "Play / Pause All Wallpapers", comment: "Global shortcut action name.")
        case .nextWallpaper:
            return String(localized: "Next Wallpaper (Active Display)", defaultValue: "Next Wallpaper (Active Display)", comment: "Global shortcut action name.")
        case .toggleMute:
            return String(localized: "Toggle Mute", defaultValue: "Toggle Mute", comment: "Global shortcut action name.")
        }
    }

    public var displayDescription: String {
        switch self {
        case .togglePlayback:
            return String(localized: "Pause every active wallpaper, or resume them all.", defaultValue: "Pause every active wallpaper, or resume them all.", comment: "Global shortcut action description.")
        case .nextWallpaper:
            return String(localized: "Advance the playlist on the display under the cursor.", defaultValue: "Advance the playlist on the display under the cursor.", comment: "Global shortcut action description.")
        case .toggleMute:
            return String(localized: "Mute or unmute every video wallpaper.", defaultValue: "Mute or unmute every video wallpaper.", comment: "Global shortcut action description.")
        }
    }

    /// Default binding shipped on first launch. Returning `nil` means the
    /// action is unbound until the user opts in — useful for future actions
    /// where we'd rather not steal a key combo by default.
    public static func defaultBinding(for action: GlobalShortcutAction) -> GlobalShortcutBinding? {
        switch action {
        case .togglePlayback:
            return GlobalShortcutBinding(keyCode: 49, modifiers: [.control, .shift]) // ⌃⇧Space
        case .nextWallpaper:
            return GlobalShortcutBinding(keyCode: 124, modifiers: [.control, .shift]) // ⌃⇧→
        case .toggleMute:
            return GlobalShortcutBinding(keyCode: 46, modifiers: [.control, .shift]) // ⌃⇧M
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

    /// Maps a small set of common keys to friendly names; falls back to
    /// `Key \(code)` for unmapped codes so debug rendering still works.
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
            return String(localized: "Key \(keyCode)", comment: "Fallback keyboard key name. The placeholder is a hardware key code.")
        }
    }

    private static func printableCharacter(for keyCode: UInt32) -> Character? {
        // Common ANSI alphabetic + digit virtual key codes. Anything outside
        // this table falls through to the numeric placeholder above.
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
