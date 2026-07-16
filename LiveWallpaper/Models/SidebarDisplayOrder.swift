import CoreGraphics
import Foundation

/// Stores a user-selected display order for the settings sidebar without
/// changing the system display order used by wallpaper rendering.
enum SidebarDisplayOrder {
    static let preferencesKey = "loomscreen.sidebar.displayOrder.v1"

    struct Entry: Codable, Equatable {
        let displayID: CGDirectDisplayID
        let fingerprint: String

        init(displayID: CGDirectDisplayID, fingerprint: String) {
            self.displayID = displayID
            self.fingerprint = fingerprint
        }

        init(screen: Screen) {
            self.init(displayID: screen.id, fingerprint: screen.displayFingerprint)
        }
    }

    static func decode(_ data: Data) -> [Entry] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func encode(_ entries: [Entry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data()
    }

    /// Applies the stored order to the currently connected displays. Exact
    /// fingerprint-and-ID matches win; a known fingerprint is then used as a
    /// fallback when macOS has assigned the same physical display a new ID.
    /// Displays without a saved entry retain the system-provided order at the
    /// end of the sidebar.
    static func orderedDisplayIDs(from available: [Entry], storedOrder: [Entry]) -> [CGDirectDisplayID] {
        var remaining = available
        var ordered = [Entry]()
        let availableFingerprintCounts = Dictionary(grouping: available, by: \.fingerprint).mapValues(\.count)
        let storedFingerprintCounts = Dictionary(grouping: storedOrder, by: \.fingerprint).mapValues(\.count)

        for storedEntry in storedOrder {
            let exactMatch = remaining.firstIndex { candidate in
                candidate.displayID == storedEntry.displayID
                    && candidate.fingerprint == storedEntry.fingerprint
            }
            // A fingerprint fallback is truthful only when it identifies one
            // row on both sides. Counts come from the original collections so
            // removing an exact match cannot make an ambiguous group appear
            // unique later in the loop.
            let canUseFingerprintFallback = !isUnknownFingerprint(storedEntry.fingerprint)
                && availableFingerprintCounts[storedEntry.fingerprint] == 1
                && storedFingerprintCounts[storedEntry.fingerprint] == 1
            let fingerprintMatch = canUseFingerprintFallback
                ? remaining.firstIndex { candidate in
                    candidate.fingerprint == storedEntry.fingerprint
                        && !isUnknownFingerprint(candidate.fingerprint)
                }
                : nil

            guard let index = exactMatch ?? fingerprintMatch else { continue }
            ordered.append(remaining.remove(at: index))
        }

        ordered.append(contentsOf: remaining)
        return ordered.map(\.displayID)
    }

    private static func isUnknownFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.hasPrefix("unknown:")
    }
}
