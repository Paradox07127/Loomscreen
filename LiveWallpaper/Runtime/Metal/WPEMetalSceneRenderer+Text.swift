#if !LITE_BUILD
import AppKit
import MetalKit

extension WPEMetalSceneRenderer {
    // MARK: - Overlay drawing

    /// Rasterizes and composites the frame's text overlays (MSDF-first, CoreText
    /// fallback) atop the rendered scene.
    func drawLiveTextOverlays(
        onto frame: MTLTexture,
        uniforms: WPEMetalRuntimeUniforms,
        liveTextByID: [String: String],
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame
    ) throws {
        guard let textRenderer, !textObjects.isEmpty else { return }
        #if DEBUG
        // Oracle/scene-debug only. `isAccumulating` is false in production after one
        // `isEnabled` read, so a normal frame builds no payload and hashes nothing.
        let tracingText = WPECanonicalTraceRecorder.shared.isAccumulating
        // Hash the frame BEFORE any text draws: this is the discriminator that tells
        // a moving `final` caused by text apart from one that arrived from upstream.
        let preCompositeSha256 = tracingText
            ? WPECanonicalTraceRecorder.shared.textureSha256(frame)
            : nil
        var textTrace: [WPECanonicalTraceRecorder.TextObjectInput] = []
        #endif
        // CoreText draws for objects that don't take the MSDF path this frame.
        var draws: [WPETextOverlayDraw] = []
        var msdfPayloads: [WPEMSDFTextDrawPayload] = []
        // Objects that DID take the MSDF path this frame, kept so their
        // CoreText fallback can be rasterized LAZILY only if the MSDF pass
        // throws (an all-or-nothing recovery). On the happy path they never
        // pay a redundant CoreText rasterize.
        var deferredMSDFObjects: [(object: WPESceneTextObject, geometry: WPETextOverlayGeometry)] = []
        draws.reserveCapacity(textObjects.count)
        // Own live visibility AND the live ancestor chain: a script hiding a
        // parent GROUP (489 加载信息) must take its text children along —
        // parse-time folding only covered the static state.
        for object in textObjects
        where (liveTextVisibility[object.id] ?? object.visible) && ancestorChainVisible(object.id) {
            let resolvedAlpha = liveTextAlpha[object.id] ?? object.resolvedAlpha(at: uniforms.time)
            guard resolvedAlpha > 0 else { continue }
            let liveText = liveTextByID[object.id] ?? object.text
            let liveObject = object.withLiveText(liveText, alpha: resolvedAlpha)
            guard let placement = textOverlayPlacement(
                for: liveObject,
                transforms: transforms,
                parallaxFrame: parallaxFrame
            ) else { continue }
            // Prefer the GPU MSDF path. Only rasterize CoreText when MSDF
            // can't build a payload this frame (glyphs still warming, or an
            // unsupported object) — the eager per-frame CoreText rasterize
            // for every object (even MSDF-happy ones) was pure redundant work.
            if let payload = msdfTextRenderer?.drawPayload(
                for: liveObject,
                sceneSize: sceneRenderSize,
                parallaxOffset: cameraUniforms.usesPerspectiveProjection
                    ? .zero
                    : placement.textParallax,
                originOverride: placement.msdfOriginOverride,
                sizeScale: Double(placement.geometry.perspectiveSizeScale),
                rotation: placement.zRotation
            ) {
                msdfPayloads.append(payload)
                deferredMSDFObjects.append((liveObject, placement.geometry))
                #if DEBUG
                if tracingText {
                    textTrace.append(Self.textTraceInput(liveObject, placement.geometry, path: "msdf"))
                }
                #endif
            } else if let draw = coreTextOverlayDraw(
                for: liveObject, geometry: placement.geometry, textRenderer: textRenderer
            ) {
                draws.append(draw)
                #if DEBUG
                if tracingText {
                    textTrace.append(Self.textTraceInput(liveObject, placement.geometry, path: "coretext"))
                }
                #endif
            }
        }
        var msdfSucceeded = false
        if !msdfPayloads.isEmpty {
            do {
                try executor.drawMSDFText(
                    payloads: msdfPayloads,
                    sceneSize: sceneRenderSize,
                    output: frame
                )
                msdfSucceeded = true
                didLogMSDFTextDrawFailure = false
            } catch {
                msdfSucceeded = false
                // This used to fail silently — every affected frame fell back to
                // CoreText with zero signal that MSDF was even attempted. Log the
                // first failure of a streak (mirrors didLogFrameFailure) so a
                // persistently-broken combo/pipeline is diagnosable instead of
                // looking like MSDF was simply never enabled.
                if !didLogMSDFTextDrawFailure {
                    Logger.warning(
                        "Scene \(descriptor.workshopID) MSDF text draw failed (\(msdfPayloads.count) payload(s)), falling back to CoreText: \(error)",
                        category: .wpeRender
                    )
                    didLogMSDFTextDrawFailure = true
                }
                debugStage("text.msdf.drawFailed", "count=\(msdfPayloads.count) error=\(error)")
            }
        }
        // If the MSDF pass threw, rasterize CoreText for the MSDF objects NOW
        // (lazily) so no text silently disappears — the safety net is
        // preserved, just no longer paid for on every happy-path frame.
        if !msdfSucceeded, !msdfPayloads.isEmpty {
            for entry in deferredMSDFObjects {
                if let draw = coreTextOverlayDraw(
                    for: entry.object, geometry: entry.geometry, textRenderer: textRenderer
                ) {
                    draws.append(draw)
                }
            }
            #if DEBUG
            if tracingText {
                // The trace must name the path that actually drew, not the one we tried.
                textTrace = textTrace.map {
                    $0.path == "msdf" ? $0.withPath("coretext-msdf-fallback") : $0
                }
            }
            #endif
        }
        if !draws.isEmpty {
            try executor.drawTextOverlays(
                overlays: draws,
                sceneSize: sceneRenderSize,
                output: frame
            )
        }
        #if DEBUG
        if tracingText {
            WPECanonicalTraceRecorder.shared.recordTextPass(
                objects: textTrace,
                preCompositeSha256: preCompositeSha256,
                target: frame
            )
        }
        #endif
    }

    #if DEBUG
    /// Snapshot one resolved text object for the canonical trace. Mirrors
    /// `coreTextOverlayDraw`'s tint fold (`rgb × brightness`) so the traced tint is
    /// the one the fragment shader actually receives.
    private static func textTraceInput(
        _ liveObject: WPESceneTextObject,
        _ geometry: WPETextOverlayGeometry,
        path: String
    ) -> WPECanonicalTraceRecorder.TextObjectInput {
        let brightness = Float(max(liveObject.brightness, 0))
        return WPECanonicalTraceRecorder.TextObjectInput(
            objectID: liveObject.id,
            name: liveObject.name,
            text: liveObject.text,
            path: path,
            center: geometry.center,
            scale: geometry.scale,
            perspectiveSizeScale: geometry.perspectiveSizeScale,
            rotation: geometry.rotation,
            alpha: Float(liveObject.alpha),
            tint: SIMD3<Float>(
                Float(liveObject.color.x) * brightness,
                Float(liveObject.color.y) * brightness,
                Float(liveObject.color.z) * brightness
            )
        )
    }
    #endif

    // MARK: - Placement

    /// Live world placement for a text object. When its ancestors are transform
    /// hosts (null groups) carrying script-driven transforms this frame, the
    /// text's LOCAL origin is re-composed through the live chain — otherwise
    /// (no live overrides, non-host parent, or no local data) the parse-time
    /// world origin stands. Mirrors `applyingLayerTransforms` composition so
    /// panel text tracks its panel background exactly.
    ///
    /// `zRotation` is the chain's composed z angle (radians, author-space CCW):
    /// WPE rotates text with its host (3470764447's 总组件角度 = -15° tilts the
    /// whole clock stack). When the live chain composes, it is the chain's
    /// composed angle; otherwise the parse-time WORLD angle stands — text
    /// objects rotate like image layers, so a static `angles` in scene.json
    /// (2986828130's Clock/Date 30° tilt) must not collapse to 0.
    func liveTextWorldPlacement(
        _ object: WPESceneTextObject,
        scriptOrigins: [String: SIMD3<Double>],
        scriptScales: [String: SIMD3<Double>],
        scriptAngles: [String: SIMD3<Double>]
    ) -> (origin: SIMD3<Double>, zRotation: Double) {
        // The text's OWN dynamic origin (a tooltip label tracking its star via
        // `shared.xxN`) is the live LOCAL origin — it takes precedence over the
        // parse-time local origin and is then composed through any live parent
        // chain (its 521-parent is identity, so it lands at the world position).
        let ownLiveOrigin = scriptOrigins[object.id]
        guard let parentID = object.parentObjectID,
              let localOrigin = ownLiveOrigin ?? object.localOrigin,
              !(scriptOrigins.isEmpty && scriptScales.isEmpty && scriptAngles.isEmpty) else {
            return (ownLiveOrigin ?? object.origin, object.angles.z)
        }
        var chain: [WPERenderObjectTransform] = []
        var cursor: String? = parentID
        var visited: Set<String> = []
        var chainIsLive = ownLiveOrigin != nil
        while let id = cursor, !visited.contains(id), visited.count < 100 {
            visited.insert(id)
            guard let hostLocal = transformHostLocalTransformsByID[id] else {
                // Non-host ancestor (image layer): its motion isn't composable
                // here — keep the parse-time origin rather than half-compose.
                return (ownLiveOrigin ?? object.origin, object.angles.z)
            }
            if scriptOrigins[id] != nil || scriptScales[id] != nil || scriptAngles[id] != nil {
                chainIsLive = true
            }
            chain.append(hostLocal.applying(
                origin: scriptOrigins[id],
                scale: scriptScales[id],
                angles: scriptAngles[id]
            ))
            cursor = objectParentByID[id]
        }
        guard chainIsLive, !chain.isEmpty else {
            return (ownLiveOrigin ?? object.origin, object.angles.z)
        }
        var world = WPERenderObjectTransform(
            origin: localOrigin,
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        for parent in chain {
            world = parent.combining(child: world)
        }
        return (world.origin, world.angles.z)
    }

    /// A text object's composed screen placement for this frame: the overlay
    /// geometry both text paths share, plus the MSDF-space origin override and
    /// parallax. nil when a perspective projection rejects the world point.
    private struct WPETextOverlayPlacement {
        let geometry: WPETextOverlayGeometry
        let msdfOriginOverride: SIMD2<Double>?
        let textParallax: SIMD2<Float>
        let zRotation: Double
    }

    private func textOverlayPlacement(
        for liveObject: WPESceneTextObject,
        transforms: LiveScriptTransforms,
        parallaxFrame: WPECameraParallaxFrame
    ) -> WPETextOverlayPlacement? {
        // A text anchored under script-driven transform hosts (menu
        // panels following the view) must re-compose its LOCAL origin
        // through the live parent chain — the parse-time world origin
        // freezes it at the load-time panel position.
        let livePlacement = liveTextWorldPlacement(
            liveObject,
            scriptOrigins: transforms.origins,
            scriptScales: transforms.scales,
            scriptAngles: transforms.angles
        )
        let liveOrigin = livePlacement.origin
        let liveRotation = Float(livePlacement.zRotation)
        let textParallax = parallaxFrame.pixelOffset(
            depth: liveObject.parallaxDepth,
            sceneSize: sceneRenderSize
        )
        let scale = SIMD2<Float>(
            Float(max(liveObject.scale.x, 0.0001)),
            Float(max(liveObject.scale.y, 0.0001))
        )
        // Perspective scenes (orthogonalprojection:null) author text
        // origins in world units, so they must project through the same
        // camera as image quads (WPEMetalRenderExecutor.perspectiveObjectQuadUniforms).
        // Treating them as pixels pushed every x≈0 label ~960px off-screen.
        // Ortho scenes keep the pixel-space placement clocks/date overlays rely on.
        let center: SIMD2<Float>
        let perspectiveSizeScale: Float
        if cameraUniforms.usesPerspectiveProjection {
            guard let projection = cameraUniforms.projectedCenterInScenePixels(
                worldPoint: liveOrigin,
                sceneSize: sceneRenderSize
            ) else { return nil }
            center = projection.center + SIMD2<Float>(textParallax.x, textParallax.y)
            perspectiveSizeScale = projection.depthScale
        } else {
            let halfWidth = Double(sceneRenderSize.width) * 0.5
            let halfHeight = Double(sceneRenderSize.height) * 0.5
            center = SIMD2<Float>(
                Float(liveOrigin.x - halfWidth) + textParallax.x,
                Float(liveOrigin.y - halfHeight) + textParallax.y
            )
            perspectiveSizeScale = 1
        }
        let geometry = WPETextOverlayGeometry(
            center: center, scale: scale, perspectiveSizeScale: perspectiveSizeScale,
            rotation: liveRotation
        )
        // In perspective the projected `center` (scene-centered, +Y up)
        // already carries parallax; convert it into the MSDF path's
        // absolute top-left pixel space so both text paths land at the
        // same screen point. The ortho live-recomposed origin is author
        // space (+Y up) like `object.origin`, so it needs the SAME
        // top-left flip + parallax fold the MSDF transform applies to
        // non-overridden origins — passing it raw y-mirrored every text
        // object the moment MSDF took over from CoreText (3470764447's
        // clock stack teleported up and reversed its line order).
        let msdfOriginOverride: SIMD2<Double>? = cameraUniforms.usesPerspectiveProjection
            ? SIMD2<Double>(
                Double(center.x) + Double(sceneRenderSize.width) * 0.5,
                Double(sceneRenderSize.height) * 0.5 - Double(center.y)
            )
            : (liveOrigin == liveObject.origin
                ? nil
                : SIMD2<Double>(
                    liveOrigin.x + Double(textParallax.x),
                    Double(sceneRenderSize.height) - (liveOrigin.y + Double(textParallax.y))
                ))
        return WPETextOverlayPlacement(
            geometry: geometry,
            msdfOriginOverride: msdfOriginOverride,
            textParallax: SIMD2<Float>(textParallax.x, textParallax.y),
            zRotation: livePlacement.zRotation
        )
    }

    /// The already-computed placement of a text object this frame, shared by the
    /// MSDF and CoreText paths so the CoreText fallback can be built lazily
    /// (only when MSDF isn't available) without recomputing projection/parallax.
    private struct WPETextOverlayGeometry {
        let center: SIMD2<Float>
        let scale: SIMD2<Float>
        let perspectiveSizeScale: Float
        /// Composed live-chain z rotation (radians, author-space CCW); 0 for
        /// static chains. Applied by both text paths so they stay in lockstep.
        let rotation: Float
    }

    // MARK: - CoreText fallback rasterization

    /// Rasterize a text object via CoreText and build its overlay draw. Called
    /// only when the MSDF path can't cover the object this frame (glyphs warming)
    /// or, on the throw-recovery path, for the MSDF objects — never eagerly for
    /// MSDF-happy objects. Returns nil when there's nothing to rasterize.
    private func coreTextOverlayDraw(
        for liveObject: WPESceneTextObject,
        geometry: WPETextOverlayGeometry,
        textRenderer: WPETextRenderer
    ) -> WPETextOverlayDraw? {
        guard let entry = textRenderer.rasterize(liveObject) else { return nil }
        let scaledSize = CGSize(
            width: entry.size.width * CGFloat(geometry.scale.x) * CGFloat(geometry.perspectiveSizeScale),
            height: entry.size.height * CGFloat(geometry.scale.y) * CGFloat(geometry.perspectiveSizeScale)
        )
        // Object `brightness` folds into the tint exactly like an image layer's
        // `rgb × brightness` (may exceed 1 — the fragment premultiplies in float,
        // so >1 brightens antialiased edges before the UNORM store clamps).
        let brightness = Float(max(liveObject.brightness, 0))
        return WPETextOverlayDraw(
            texture: entry.texture,
            centerInScenePixels: geometry.center,
            sizeInScenePixels: scaledSize,
            tint: SIMD3<Float>(
                Float(liveObject.color.x) * brightness,
                Float(liveObject.color.y) * brightness,
                Float(liveObject.color.z) * brightness
            ),
            alpha: Float(liveObject.alpha),
            rotation: geometry.rotation
        )
    }

    // MARK: - Loading

    /// Phase 2D-O: spin up the audio runtime and start playback if the scene declared sound objects.
    /// Phase 2D-N: build the WPETextRenderer + cache the parsed text object list.
    func loadTextOverlays(from document: WPESceneDocument) {
        textObjects = document.textObjects
        guard !textObjects.isEmpty else {
            textRenderer = nil
            msdfTextRenderer = nil
            textScriptInstances.removeAll(keepingCapacity: false)
            return
        }
        textRenderer = WPETextRenderer(
            device: executor.textureSourceDevice,
            resolver: resourceResolver
        )
        // GPU MSDF text is ON by default: glyph generation runs off the main
        // thread (77059619) and the clean-room `font.frag` ships in
        // wpe-builtins.bundle, so the shader resolves for every install. The
        // flag stays as a kill-switch for this visual-fidelity feature —
        // disable with: defaults write <bundle> WPEEnableMSDFText -bool NO
        // A resolver miss (or any draw failure) still falls back to the
        // CoreText overlay; multi-line text always renders via CoreText.
        if UserDefaults.standard.object(forKey: "WPEEnableMSDFText") as? Bool ?? true,
           let fontFragmentSource = resolveMSDFFontFragmentSource() {
            msdfTextRenderer = WPEMSDFTextRenderer(
                device: executor.textureSourceDevice,
                resolver: resourceResolver,
                fontFragmentSource: fontFragmentSource
            )
        } else {
            msdfTextRenderer = nil
        }
        textScriptInstances.removeAll(keepingCapacity: false)
        let sharedState = sceneScriptSharedState ?? WPESharedScriptState()
        sceneScriptSharedState = sharedState
        for object in textObjects {
            guard let script = object.textScript else { continue }
            do {
                let instance = try WPESceneScriptInstance(
                    script: script,
                    initialValue: object.text,
                    scriptProperties: object.scriptProperties,
                    shared: sharedState
                )
                // Seeding happens in seedSceneScriptsAfterLoad() — AFTER the
                // layer/script-host instances exist and have produced their
                // first `shared` state, never here (WPE evaluation order).
                textScriptInstances[object.id] = instance
            } catch {
                Logger.warning("Scene \(descriptor.workshopID) [TextScript] init failed for \(object.name): \(error)", category: .wpeRender)
            }
        }
    }

    /// Loads the MSDF `font.frag` for the GPU text path. Resolves through the
    /// standard cascade — a scene's own override first, then the clean-room copy
    /// in `wpe-builtins.bundle` (present for every install), then an optional
    /// engine-assets root. Returns nil when unavailable → CoreText only.
    func resolveMSDFFontFragmentSource() -> String? {
        let candidates = ["shaders/font.frag", "shaders/effects/font.frag"]
        for path in candidates {
            guard let data = try? resourceResolver.data(relativePath: path, optional: true),
                  let source = String(data: data, encoding: .utf8) else {
                continue
            }
            return source
        }
        return nil
    }
}
#endif
