import Foundation

enum WPEResolutionOrigin: Hashable, Sendable {
    case scene
    case builtin
    case engineAssets
    case dependency(String)

    var debugLabel: String {
        switch self {
        case .scene:
            return "scene"
        case .builtin:
            return "builtin"
        case .engineAssets:
            return "engineAssets"
        case .dependency(let workshopID):
            return "dependency(\(workshopID))"
        }
    }
}

enum WPEResolutionOutcome: Equatable, Sendable {
    case resolved
    case fileMissing
    case otherError(String)

    var debugLabel: String {
        switch self {
        case .resolved:
            return "resolved"
        case .fileMissing:
            return "fileMissing"
        case .otherError(let reason):
            return "otherError(\(reason))"
        }
    }
}

struct WPEResolutionAttempt: Equatable, Sendable {
    let origin: WPEResolutionOrigin
    let outcome: WPEResolutionOutcome
}

struct WPEResolutionEvent: Equatable, Sendable {
    let ref: String
    let attempts: [WPEResolutionAttempt]
    let finalOutcome: WPEResolutionOutcome
}

struct WPEResolutionDiagnosticsSnapshot: Equatable, Sendable {
    let events: [WPEResolutionEvent]

    var resolvedCount: Int {
        events.lazy.filter { $0.finalOutcome == .resolved }.count
    }

    var resolvedByOrigin: [WPEResolutionOrigin: Int] {
        var counts: [WPEResolutionOrigin: Int] = [:]
        for event in events where event.finalOutcome == .resolved {
            guard let hit = event.attempts.last, hit.outcome == .resolved else { continue }
            counts[hit.origin, default: 0] += 1
        }
        return counts
    }

    var missedRefs: [WPEResolutionEvent] {
        events.filter { $0.finalOutcome != .resolved }
    }
}

/// Mutable accumulator shared across one scene-load lifetime. Uses NSLock
/// rather than an actor because the resolver chain is sync — moving to an
/// actor would force every `resolveImage(...)` call to become async, which
/// ripples through the entire runtime.
final class WPEResolutionTracer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WPEResolutionEvent] = []

    func record(_ event: WPEResolutionEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> WPEResolutionDiagnosticsSnapshot {
        lock.lock()
        let copy = events
        lock.unlock()
        return WPEResolutionDiagnosticsSnapshot(events: copy)
    }

    func reset() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
