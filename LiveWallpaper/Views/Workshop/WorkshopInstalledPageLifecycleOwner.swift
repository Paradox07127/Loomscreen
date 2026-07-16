#if !LITE_BUILD
    import AppKit
    import Foundation

    struct WorkshopInstalledLocalInfoLoadIdentity: Hashable, Sendable {
        let entryID: String
        let importedAt: Date
    }

    @MainActor
    final class WorkshopInstalledLocalInfoLoadOwner {
        struct Ticket: Equatable, Sendable {
            let identity: WorkshopInstalledLocalInfoLoadIdentity
            let generation: UInt64
        }

        private var generation: UInt64 = 0
        private var currentTicket: Ticket?

        func begin(identity: WorkshopInstalledLocalInfoLoadIdentity) -> Ticket {
            generation &+= 1
            let ticket = Ticket(identity: identity, generation: generation)
            currentTicket = ticket
            return ticket
        }

        func canPublish(_ ticket: Ticket) -> Bool {
            currentTicket == ticket && !Task.isCancelled
        }

        func invalidate() {
            generation &+= 1
            currentTicket = nil
        }
    }

    /// Owns Installed-page work whose lifetime must not be left to transient
    /// SwiftUI view values: AppKit event monitors and the replaceable update check.
    @MainActor
    final class WorkshopInstalledPageLifecycleOwner {
        struct UpdateTicket: Equatable, Sendable {
            let generation: UInt64
            fileprivate let token: UUID
        }

        struct UpdateResult<Value: Sendable>: Sendable {
            fileprivate let ticket: UpdateTicket
            let value: Value
        }

        struct DragMonitorHooks {
            let installLocal: (@escaping @MainActor () -> Void) -> Any?
            let installGlobal: (@escaping @MainActor () -> Void) -> Any?
            let remove: (Any) -> Void

            @MainActor static let appKit = DragMonitorHooks(
                installLocal: { onEnd in
                    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
                        if event.type == .leftMouseUp || (event.type == .keyDown && event.keyCode == 53) {
                            Task { @MainActor in onEnd() }
                        }
                        return event
                    }
                },
                installGlobal: { onEnd in
                    NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
                        Task { @MainActor in onEnd() }
                    }
                },
                remove: { NSEvent.removeMonitor($0) }
            )
        }

        private struct UpdateHandle: Sendable {
            let ticket: UpdateTicket
            let cancel: @Sendable () -> Void
        }

        private nonisolated(unsafe) let monitorHooks: DragMonitorHooks
        private nonisolated(unsafe) var localDragEndMonitor: Any?
        private nonisolated(unsafe) var globalDragEndMonitor: Any?
        private var updateGeneration: UInt64 = 0
        private var updateHandle: UpdateHandle?

        init(monitorHooks: DragMonitorHooks = .appKit) {
            self.monitorHooks = monitorHooks
        }

        deinit {
            updateHandle?.cancel()
            removeDragEndMonitorsFromAnyIsolation()
        }

        var activeDragMonitorCount: Int {
            (localDragEndMonitor == nil ? 0 : 1) + (globalDragEndMonitor == nil ? 0 : 1)
        }

        var hasActiveUpdate: Bool {
            updateHandle != nil
        }

        func installDragEndMonitors(onEnd: @escaping @MainActor () -> Void) {
            removeDragEndMonitors()
            localDragEndMonitor = monitorHooks.installLocal(onEnd)
            globalDragEndMonitor = monitorHooks.installGlobal(onEnd)
        }

        func removeDragEndMonitors() {
            removeDragEndMonitorsFromAnyIsolation()
        }

        /// Replaces any previous check. The returned result remains uncommitted and
        /// keeps its ticket live until `commitUpdate` validates it synchronously.
        func replaceUpdate<Value: Sendable>(
            operation: @escaping @MainActor (UpdateTicket) async -> Value?
        ) async -> UpdateResult<Value>? {
            cancelUpdate()
            updateGeneration &+= 1
            let ticket = UpdateTicket(generation: updateGeneration, token: UUID())
            let task = Task { @MainActor in
                await operation(ticket)
            }
            updateHandle = UpdateHandle(ticket: ticket, cancel: { task.cancel() })

            let value = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }

            guard canContinue(ticket), let value else {
                finishUpdate(ticket)
                return nil
            }
            return UpdateResult(ticket: ticket, value: value)
        }

        /// Validation, state publication and ticket retirement are one MainActor
        /// turn, so replacement cannot interleave with a partially committed cache.
        @discardableResult
        func commitUpdate<Value: Sendable>(
            _ result: UpdateResult<Value>,
            commit: (Value) -> Void
        ) -> Bool {
            guard updateHandle?.ticket == result.ticket, !Task.isCancelled else {
                finishUpdate(result.ticket)
                return false
            }
            commit(result.value)
            finishUpdate(result.ticket)
            return true
        }

        func canContinue(_ ticket: UpdateTicket) -> Bool {
            updateHandle?.ticket == ticket && !Task.isCancelled
        }

        func cancelUpdate() {
            updateGeneration &+= 1
            let handle = updateHandle
            updateHandle = nil
            handle?.cancel()
        }

        func tearDown() {
            cancelUpdate()
            removeDragEndMonitors()
        }

        private func finishUpdate(_ ticket: UpdateTicket) {
            guard updateHandle?.ticket == ticket else { return }
            updateHandle = nil
        }

        private nonisolated func removeDragEndMonitorsFromAnyIsolation() {
            if let localDragEndMonitor {
                monitorHooks.remove(localDragEndMonitor)
                self.localDragEndMonitor = nil
            }
            if let globalDragEndMonitor {
                monitorHooks.remove(globalDragEndMonitor)
                self.globalDragEndMonitor = nil
            }
        }
    }
#endif
