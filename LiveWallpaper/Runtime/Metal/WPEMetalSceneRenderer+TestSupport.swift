#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit
import os

#if DEBUG
// Test-only scaffolding: adopt the renderer into a main-backed `WPEDisplayRenderActor`
// so unit tests keep the pre-off-main `try await renderer.load()` shape without
// reaching into production surface/actor wiring. Never compiled into release.
extension WPEMetalSceneRenderer {
    /// Test-only: the MTKView of the surface built by the convenience init.
    @MainActor var nsView: NSView { debugSurface!.mtkView }

    /// Test-only strong hold on the lazily-created main-backed actor, so the weak
    /// `displayActor` back-link stays alive across the whole test (otherwise the
    /// deferred-audio / static-reload tails would silently no-op after `load()`).
    private static let debugActorsLock = OSAllocatedUnfairLock<[ObjectIdentifier: WPEDisplayRenderActor]>(initialState: [:])

    /// Test-only: lazily adopt this renderer into a main-backed actor (once) and
    /// run its load. Mirrors what the production builder does, so tests keep the
    /// pre-flip `try await renderer.load()` shape. `@MainActor` so a main-thread
    /// test calls it without `sending` self across an isolation boundary.
    @MainActor
    private func debugAdoptedActor() async -> WPEDisplayRenderActor {
        if let actor = displayActor { return actor }
        let actor = WPEDisplayRenderActor(backing: .main)
        let key = ObjectIdentifier(self)
        Self.debugActorsLock.withLock { $0[key] = actor }
        await actor.adopt(WPERendererHandoff(renderer: self).renderer)
        return actor
    }

    @MainActor
    func load() async throws {
        try await debugAdoptedActor().load()
    }

    @MainActor
    func reload() async throws {
        try await debugAdoptedActor().reload()
    }

    @MainActor
    func captureLivePosterFromNextFrame() async -> NSImage? {
        await debugAdoptedActor().captureLivePoster()
    }

    /// Drops the strong test-actor hold on cleanup so a torn-down test renderer
    /// (and the actor that retains it) can deallocate.
    func releaseDebugActorIfNeeded() {
        let key = ObjectIdentifier(self)
        Self.debugActorsLock.withLock { $0[key] = nil }
    }
}
#endif
#endif
