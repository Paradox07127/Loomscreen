import SwiftUI

public extension SymbolEffectOptions {
    /// "Repeat indefinitely with the smoothest possible cadence."
    ///
    /// On macOS 15+ this is the `repeat(.continuous)` form — designed for
    /// seamless effects like rotation. On macOS 14 the closest option is the
    /// legacy `.repeating`, which actually maps to a periodic cadence; we use
    /// it as a fallback because no continuous variant exists on that OS.
    ///
    /// Use this instead of `.repeating` when the call site previously read
    /// `.repeat(.continuous)`, so users on macOS 15+ keep the smoother
    /// animation rather than dropping to the older periodic pulse.
    static var continuouslyRepeating: SymbolEffectOptions {
        if #available(macOS 15.0, *) {
            return .repeat(.continuous)
        } else {
            return .repeating
        }
    }
}
