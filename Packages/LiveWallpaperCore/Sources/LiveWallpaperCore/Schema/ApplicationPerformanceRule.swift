import Foundation

/// A user-defined "pause the wallpaper while this app is in use" rule, keyed by
/// bundle identifier. Evaluation is event-driven off `NSWorkspace` activation /
/// launch / terminate notifications — no polling — so an empty rule list costs
/// nothing and a populated one only does a small bundle-ID comparison when an
/// app actually activates, launches, or quits.
public struct ApplicationPerformanceRule: Codable, Equatable, Sendable, Identifiable {
    public enum Trigger: String, Codable, Sendable {
        /// Pause only while the app is the frontmost (active) application.
        case frontmost
        /// Pause whenever the app is running, even in the background.
        case running
        /// Never pause while this app is frontmost — vetoes auto game-mode /
        /// full-screen / occlusion / battery pauses so the user can "un-flag" a
        /// mis-detected app. Safety pauses (thermal / memory / idle) still win.
        case neverPause
    }

    public var bundleID: String
    public var displayName: String
    public var trigger: Trigger

    public var id: String { bundleID }

    public init(bundleID: String, displayName: String, trigger: Trigger = .frontmost) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.trigger = trigger
    }
}
