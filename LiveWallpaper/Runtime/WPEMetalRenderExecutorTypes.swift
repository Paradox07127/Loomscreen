#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
import os
import simd

/// Shared classifier for WPE compose/project utility layers, so the dispatcher,
/// target pool, and executor branch on one definition instead of duplicating
/// path checks.
enum WPEMetalSceneCaptureUtilityModels {
    /// WPE `fullscreen`/`passthrough` utility models — `composelayer.json`,
    /// `projectlayer.json`, and `fullscreenlayer.json` (the post-process /
    /// depth-of-field carrier) — all capture the full frame and MUST render
    /// fullscreen with a scene-sized composite. Drawing them at their authored
    /// object footprint shrinks the result into a "picture-in-picture" panel
    /// (e.g. scene 3479521040's DoF layer was a `fullscreenlayer`). Tolerates a
    /// leading `../<dependencyID>/` resolver prefix.
    static func isSceneCaptureUtilityModelPath(_ path: String) -> Bool {
        WPEUtilityModelKind.isUtilityModelPath(path)
    }

    /// Output geometry for a scene-capture utility (passthrough) layer's scene
    /// composite. Fullscreen/project utility layers capture 1:1 full-frame (the
    /// 98f79b5 lesson); a plain `composelayer.json` that hosts a spatial effect
    /// authored into a real sub-rect captures the matching scene area into its
    /// local target and is confined to that box.
    enum OutputGeometry { case fullscreen, subregion }

    /// `fullscreenlayer.json` (DoF/post-process) and `projectlayer.json`
    /// (projection/autosize) always cover the frame. A `composelayer.json`
    /// stays fullscreen too unless its authored footprint is a safe sub-scene
    /// rectangle: finite, mirrorable by the object-quad path, and clearly
    /// smaller than the scene. Oversized / full-coverage compose layers stay
    /// fullscreen — this preserves 98f79b5's decision for scene 3479521040's
    /// 5000×2300 rotated passthrough layer. Small z-rotated local compose
    /// layers (scene 2986828130's prism/audio box) stay subregion and capture
    /// the matching scene area into their local target.
    static func outputGeometry(
        path: String,
        geometry: WPERenderLayerGeometry,
        sceneSize: CGSize
    ) -> OutputGeometry {
        guard WPEUtilityModelKind.classify(path) == .composeLayer else { return .fullscreen }
        guard let size = geometry.size else { return .fullscreen }
        let sceneW = max(Float(sceneSize.width), 1)
        let sceneH = max(Float(sceneSize.height), 1)
        let width = Float(size.width) * max(abs(Float(geometry.scale.x)), 0.0001)
        let height = Float(size.height) * max(abs(Float(geometry.scale.y)), 0.0001)
        guard width.isFinite, height.isFinite, width > 1, height > 1 else { return .fullscreen }
        let rotationEpsilon: Float = 0.001
        let zAxisTurn = normalizedAbsoluteZTurn(Float(geometry.angles.z))
        let isHalfTurn = abs(zAxisTurn - .pi) <= rotationEpsilon
        if abs(Float(geometry.angles.x)) > rotationEpsilon
            || abs(Float(geometry.angles.y)) > rotationEpsilon {
            return .fullscreen
        }
        let flipsX = geometry.scale.x < 0
        let flipsY = geometry.scale.y < 0
        if flipsX != flipsY && !isHalfTurn { return .fullscreen }
        let fullCoverage: Float = 0.95
        if width >= sceneW * fullCoverage && height >= sceneH * fullCoverage { return .fullscreen }
        return .subregion
    }

    private static func normalizedAbsoluteZTurn(_ radians: Float) -> Float {
        guard radians.isFinite else { return .infinity }
        return abs(radians.remainder(dividingBy: 2 * .pi))
    }
}

/// Thread-safe sink for GPU command-buffer errors. They surface in the
/// completed handler on a GPU thread *after* the frame call returned, so they
/// can't throw — recorded here and surfaced in the scene diagnostic log. Bounded
/// to count + last message so a persistently-failing GPU never grows memory.
final class WPEGPUErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var errorCount = 0
    private var lastMessage: String?

    func record(_ message: String) {
        lock.lock()
        errorCount += 1
        lastMessage = message
        lock.unlock()
    }

    var summary: (count: Int, last: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (errorCount, lastMessage)
    }
}

/// Custom-shader compile failures, deduped by shader name, surfaced in the scene
/// diagnostic log — the `WPESceneDebugArtifacts` dump is hard-off in Release, so
/// otherwise a skipped (non-compiling) pass is invisible in a bug report.
final class WPEShaderErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: String] = [:]

    func record(shader: String, reason: String) {
        lock.lock()
        failures[shader] = reason
        lock.unlock()
    }

    var summary: (count: Int, entries: [(shader: String, reason: String)]) {
        lock.lock()
        defer { lock.unlock() }
        let entries = failures.sorted { $0.key < $1.key }.map { (shader: $0.key, reason: $0.value) }
        return (entries.count, entries)
    }
}
#endif
