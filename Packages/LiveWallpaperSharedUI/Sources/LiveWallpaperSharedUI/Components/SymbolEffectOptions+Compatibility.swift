import SwiftUI

public extension SymbolEffectOptions {
    /// Smoothest available repeat cadence. macOS 15+ gets `repeat(.continuous)`
    /// (seamless, for rotation etc.); macOS 14 falls back to the legacy
    /// `.repeating` periodic cadence because no continuous variant exists there.
    static var continuouslyRepeating: SymbolEffectOptions {
        if #available(macOS 15.0, *) {
            return .repeat(.continuous)
        } else {
            return .repeating
        }
    }
}
