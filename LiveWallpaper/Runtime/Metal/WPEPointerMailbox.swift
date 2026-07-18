#if !LITE_BUILD
import CoreGraphics
import Foundation
import os
import simd

/// Non-blocking hand-off of pointer state from the main thread (writer: mouse
/// events, window geometry, capture toggle) to the render thread (reader).
///
/// Mirrors `AudioSpectrumBroker`: one `OSAllocatedUnfairLock` over a Sendable
/// value struct, last-write-wins on every slot, torn-free consistent snapshot on
/// read. Writers are `nonisolated` so the main-thread publisher, the view's
/// event handlers, and the renderer can all feed it without hopping actors.
///
/// Wiring (M2c1a, live on `@MainActor`): `renderer.makeFrameInputs()` reads
/// `mailbox.read()` — `Reading` maps 1:1 onto the pointer fields of
/// `WPEFrameInputs`. `WPEPointerPublisher` feeds mouse + geometry;
/// `WPEInteractiveMTKView`'s `onPointerFrameChange` feeds `pointerFrame`; the
/// renderer's Interaction toggle (via the surface) feeds `clickCaptureEnabled`.
/// All feed paths are on main today; the render read is already NSView-free so
/// it survives the eventual move off `@MainActor` (M2c1b).
final class WPEPointerMailbox: Sendable {
    /// The view's frame in screen coordinates (bottom-left origin), captured on
    /// the main thread whenever the window moves / resizes / changes screen. A
    /// zero-size rect means "no active surface" and resolves samples to
    /// `.inactive`, matching `sampleSceneUV`'s no-window / zero-bounds guard.
    struct Geometry: Equatable, Sendable {
        var viewFrameInScreen: CGRect
        static let none = Geometry(viewFrameInScreen: .zero)
    }

    /// One torn-free view of everything the renderer's pointer path consumes.
    struct Reading: Equatable, Sendable {
        var pointerSample: WPEMetalPointerSample
        var pointerFrame: WPEPointerFrame
        var clickCaptureEnabled: Bool
        var mouseTimestampNanos: UInt64
    }

    private struct State {
        var mouseScreenLocation: CGPoint
        var mouseTimestampNanos: UInt64
        var geometry: Geometry
        var pointerFrame: WPEPointerFrame
        var clickCaptureEnabled: Bool
    }

    private let lock = OSAllocatedUnfairLock(
        initialState: State(
            // Off-screen sentinel: before the first geometry/mouse push, any read
            // maps to `.inactive` (geometry is `.none`, so the location is moot).
            mouseScreenLocation: CGPoint(x: -.greatestFiniteMagnitude,
                                         y: -.greatestFiniteMagnitude),
            mouseTimestampNanos: 0,
            geometry: .none,
            pointerFrame: .neutral,
            clickCaptureEnabled: false
        )
    )

    // MARK: - Writers (last-write-wins)

    func publishMouseLocation(_ screenLocation: CGPoint, timestampNanos: UInt64) {
        lock.withLock { state in
            state.mouseScreenLocation = screenLocation
            state.mouseTimestampNanos = timestampNanos
        }
    }

    func publishGeometry(_ geometry: Geometry) {
        lock.withLock { $0.geometry = geometry }
    }

    func publishPointerFrame(_ frame: WPEPointerFrame) {
        lock.withLock { $0.pointerFrame = frame }
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        lock.withLock { $0.clickCaptureEnabled = enabled }
    }

    // MARK: - Reader

    func read() -> Reading {
        lock.withLock { state in
            Reading(
                pointerSample: Self.pointerSample(
                    forScreenLocation: state.mouseScreenLocation,
                    geometry: state.geometry
                ),
                pointerFrame: state.pointerFrame,
                clickCaptureEnabled: state.clickCaptureEnabled,
                mouseTimestampNanos: state.mouseTimestampNanos
            )
        }
    }

    // MARK: - Pure mapping

    /// NSView-free re-implementation of `WPEMetalPointerSampler.sampleSceneUV`
    /// (WPEMetalRuntimeUniforms.swift), so the render thread can resolve the
    /// sample without touching AppKit. The screen frame is a rigid translation of
    /// the view's bounds, so `rect.contains(location)` is exactly the original
    /// `bounds.contains(localPoint)` and the UV math below is identical.
    /// Assumes the wallpaper view fills its window with an identity bounds↔frame
    /// transform (no scaling) — the wallpaper invariant; if a view ever scales,
    /// carry the bounds size in `Geometry` and divide by it here.
    static func pointerSample(
        forScreenLocation location: CGPoint,
        geometry: Geometry
    ) -> WPEMetalPointerSample {
        let rect = geometry.viewFrameInScreen
        guard rect.width > 0, rect.height > 0, rect.contains(location) else {
            return .inactive
        }
        let x = Double((location.x - rect.minX) / rect.width)
        let y = 1.0 - Double((location.y - rect.minY) / rect.height)
        return .inside(SIMD2<Double>(x, y))
    }
}
#endif
