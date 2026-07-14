import Foundation
import Network
import os

/// A single long-lived `NWPathMonitor` on its own queue. The Network framework is
/// event-driven (a callback only fires when the path changes) and needs no
/// entitlement beyond `network.client`, which is already present. The latest path
/// snapshot is cached under a lock so the polling sampler thread can read it cheaply
/// and thread-safely; `activeInterfaceName` lets the network sampler mark the
/// system-chosen interface as active.
final class MonitorNetworkPathObserver: Sendable {
    struct Snapshot: Sendable, Equatable {
        var path: MonitorNetworkPath
        /// BSD name (e.g. "en0") of the first available interface on the chosen path.
        var activeInterfaceName: String?
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.livewallpaper.monitor.netpath", qos: .utility)
    private let latest = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)
    private let started = OSAllocatedUnfairLock(initialState: false)

    func start() {
        let alreadyStarted = started.withLock { value -> Bool in
            if value { return true }
            value = true
            return false
        }
        guard !alreadyStarted else { return }

        let store = latest
        monitor.pathUpdateHandler = { path in
            store.withLock { $0 = Self.snapshot(from: path) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        let wasStarted = started.withLock { value -> Bool in
            let previous = value
            value = false
            return previous
        }
        guard wasStarted else { return }
        monitor.cancel()
    }

    func currentSnapshot() -> Snapshot? {
        latest.withLock { $0 }
    }

    private static func snapshot(from path: NWPath) -> Snapshot {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }

        var interfaceType: String?
        if path.usesInterfaceType(.wifi) {
            interfaceType = "wifi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceType = "wired"
        } else if path.usesInterfaceType(.cellular) {
            interfaceType = "cellular"
        } else if path.usesInterfaceType(.other) || path.usesInterfaceType(.loopback) {
            interfaceType = "other"
        }

        let activeName = path.availableInterfaces.first?.name

        return Snapshot(
            path: MonitorNetworkPath(
                status: status,
                interfaceType: interfaceType,
                isConstrained: path.isConstrained,
                isExpensive: path.isExpensive
            ),
            activeInterfaceName: activeName
        )
    }
}
