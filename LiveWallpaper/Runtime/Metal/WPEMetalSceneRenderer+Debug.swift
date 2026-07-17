#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import MetalKit

extension WPEMetalSceneRenderer {
    #if DEBUG
    // MARK: - GPU capture gating

    /// Whether the current scene is in the GPU-capture set. `WPEMetalCaptureScene`
    /// holds a string array (the Developer Tools "GPU capture" list); a single
    /// `defaults write ... WPEMetalCaptureScene <id>` string — optionally comma/
    /// space separated — is still honored for back-compat with the CLI workflow.
    private func gpuCaptureRequestedForCurrentScene() -> Bool {
        let d = UserDefaults.standard
        let raw: [String]
        if let arr = d.stringArray(forKey: "WPEMetalCaptureScene") {
            raw = arr
        } else if let s = d.string(forKey: "WPEMetalCaptureScene") {
            raw = s.split(whereSeparator: { ",; ".contains($0) }).map(String.init)
        } else {
            raw = []
        }
        let wanted = Set(raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return wanted.contains(descriptor.workshopID)
    }
    #endif

    // MARK: - Texture & pass PNG dumps

    /// Iterate every entry in `loadedTextures` and dump each to a PNG so we
    /// can verify whether the source-image upload actually carried bytes to
    /// the GPU. Same gate as the GPU trace + outputTexture dump.
    func dumpLoadedTexturesIfRequested() {
        #if DEBUG
        guard gpuCaptureRequestedForCurrentScene() else { return }
        for (path, texture) in loadedTextures {
            let safeName = path
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            dumpTextureToPNG(texture, basename: "tex-\(safeName)")
        }
        #endif
    }

    #if DEBUG
    /// Dump one PNG per scene-target pass (collected by the executor when
    /// `WPEDumpScenePasses` matches this scene) so we can see exactly which pass
    /// introduces an artifact. PNGs land in App Support/LiveWallpaper/gpu-traces/
    /// as `wpe-<id>-scenepass-NN-<passid>-WxH.png`, ordered by draw sequence.
    func dumpScenePassesIfRequested(suffix: String = "") {
        let wantedID = UserDefaults.standard.string(forKey: "WPEDumpScenePasses")
        let pngRequested = (wantedID?.isEmpty == false) && wantedID == descriptor.workshopID
        // Oracle mode attaches per-pass output hashes to the canonical trace even
        // without the workshopID-scoped PNG flag, and skips the (expensive) PNG
        // encode. `recordPassOutputs` matches by pass id, so passing the full dump
        // list is idempotent.
        guard pngRequested || WPEOracleMode.perPassHashesEnabled else { return }
        let dumps = executor.scenePassDumps
        WPECanonicalTraceRecorder.shared.recordPassOutputs(dumps)
        guard pngRequested else { return }
        Logger.notice(
            "[WPEDumpScenePasses] dumping \(dumps.count) scene-target passes\(suffix.isEmpty ? " (t0)" : " \(suffix)") for \(descriptor.workshopID)",
            category: .wpeRender
        )
        for (index, entry) in dumps.enumerated() {
            let safeLabel = entry.label
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ".", with: "_")
            let ordinal = index < 10 ? "0\(index)" : "\(index)"
            dumpTextureToPNG(entry.texture, basename: "scenepass\(suffix)-\(ordinal)-\(safeLabel)")
        }
    }

    /// One-shot per-pass + composite dump once scene time crosses a threshold
    /// (default 6s, override via env `WPEDumpScenePassesAtTime`). Lets us see
    /// time-animated artifacts (e.g. a face distorted by an animated effect over
    /// time) that the first-frame dump at t≈0 misses. Same `WPEDumpScenePasses`
    /// gate. `composite` is the post-particle/text frame the user actually sees.
    func maybeDumpScenePassesOverTime(time: Double, composite: MTLTexture) {
        guard !didDumpScenePassesOverTime else { return }
        let wantedID = UserDefaults.standard.string(forKey: "WPEDumpScenePasses")
        guard let wantedID, !wantedID.isEmpty, wantedID == descriptor.workshopID else { return }
        let threshold = ProcessInfo.processInfo.environment["WPEDumpScenePassesAtTime"].flatMap(Double.init) ?? 6.0
        guard time >= threshold else { return }
        didDumpScenePassesOverTime = true
        let tag = "t\(Int(time.rounded()))s"
        dumpScenePassesIfRequested(suffix: "-\(tag)")
        dumpTextureToPNG(composite, basename: "composite-\(tag)")
    }

    private func dumpTextureToPNG(_ rawTexture: MTLTexture, basename: String) {
        let texture: MTLTexture
        var overrideBytes: [UInt8]?
        if rawTexture.pixelFormat == .rgba8Unorm || rawTexture.pixelFormat == .rgba8Unorm_srgb {
            texture = rawTexture
        } else if rawTexture.pixelFormat == .rgba16Float {
            // The sampling fallback below renders HDR float targets black; the
            // snapshotter's CPU clamp+sRGB conversion is the correct viewer.
            overrideBytes = WPEMetalTextureSnapshotter.convertRGBA16FloatToSRGB8(rawTexture)
            texture = rawTexture
        } else if let decoded = executor.debugDecodeToRGBA(rawTexture) {
            // BC/DXT/RG88/R8 etc. — decode by sampling into rgba8 so we can view it.
            texture = decoded
        } else {
            Logger.info(
                "[gpu-dump] texture dump: unsupported pixel format \(rawTexture.pixelFormat.rawValue) for \(basename)",
                category: .wpeRender
            )
            return
        }
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        let bytes: [UInt8]
        if let overrideBytes {
            bytes = overrideBytes
        } else {
            var readback = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
            texture.getBytes(
                &readback,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0
            )
            bytes = readback
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            Logger.info("[gpu-dump] texture dump: CGDataProvider failed for \(basename)", category: .wpeRender)
            return
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            Logger.info("[gpu-dump] texture dump: CGImage failed for \(basename)", category: .wpeRender)
            return
        }

        let nsImage = NSImage(cgImage: cgImage, size: CGSize(width: texture.width, height: texture.height))
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = support
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("gpu-traces", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(
                "wpe-\(descriptor.workshopID)-\(basename)-\(texture.width)x\(texture.height).png"
            )
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                Logger.info("[gpu-dump] texture dump: PNG encode failed for \(basename)", category: .wpeRender)
                return
            }
            try png.write(to: url)
            Logger.notice("[gpu-dump] texture dump → \(url.path)", category: .wpeRender)
        } catch {
            Logger.info(
                "[gpu-dump] texture dump failed for \(basename): \(error.localizedDescription)",
                category: .wpeRender
            )
        }
    }
    #endif

    /// Writes the raw post-render `outputTexture` (the scene render output
    /// *before* present blit) to disk as a PNG via a GPU blit into a
    /// `.storageModeShared` `MTLBuffer` — the robust readback path for
    /// large textures where `texture.getBytes(...)` can silently return
    /// stale bytes on some driver/storage combos. Gated on the same
    /// `WPEMetalCaptureScene` UserDefault as the GPU trace capture.
    func dumpOutputTextureIfRequested(_ texture: MTLTexture) {
        #if DEBUG
        guard gpuCaptureRequestedForCurrentScene() else { return }
        let device = texture.device
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            Logger.info(
                "[WPEMetalCaptureScene] outputTexture dump: unsupported pixel format \(texture.pixelFormat.rawValue)",
                category: .wpeRender
            )
            return
        }
        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        let totalBytes = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: totalBytes, options: .storageModeShared) else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: makeBuffer failed", category: .wpeRender)
            return
        }
        guard let queue = device.makeCommandQueue(),
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: cannot create blit encoder", category: .wpeRender)
            return
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: totalBytes
        )
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else {
            Logger.info(
                "[WPEMetalCaptureScene] outputTexture dump: blit failed (status=\(cb.status.rawValue))",
                category: .wpeRender
            )
            return
        }

        let provider = CGDataProvider(dataInfo: nil, data: buffer.contents(), size: totalBytes) { _, _, _ in }
        guard let provider else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: CGDataProvider failed", category: .wpeRender)
            return
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            Logger.info("[WPEMetalCaptureScene] outputTexture dump: CGImage failed", category: .wpeRender)
            return
        }
        let nsImage = NSImage(cgImage: cg, size: CGSize(width: texture.width, height: texture.height))
        let fm = FileManager.default
        do {
            let support = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = support
                .appendingPathComponent("LiveWallpaper", isDirectory: true)
                .appendingPathComponent("gpu-traces", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(
                "wpe-\(descriptor.workshopID)-output-\(texture.width)x\(texture.height).png"
            )
            guard let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                Logger.info("[WPEMetalCaptureScene] outputTexture dump: PNG encode failed", category: .wpeRender)
                return
            }
            try png.write(to: url)
            // Also probe the buffer contents directly so we have a numeric
            // sanity check independent of CG / PNG encoding: how many of the
            // first 64 KB of bytes are non-zero.
            let probe = buffer.contents().assumingMemoryBound(to: UInt8.self)
            let probeLength = min(64 * 1024, totalBytes)
            var nonZero = 0
            for i in 0..<probeLength where probe[i] != 0 { nonZero += 1 }
            Logger.notice(
                "[WPEMetalCaptureScene] outputTexture dump → \(url.path) (first \(probeLength) bytes: \(nonZero) non-zero)",
                category: .wpeRender
            )
        } catch {
            Logger.info(
                "[WPEMetalCaptureScene] outputTexture dump failed: \(error.localizedDescription)",
                category: .wpeRender
            )
        }
        #endif
    }

    // MARK: - GPU capture

    /// DEBUG-only `MTLCaptureManager` wrap around `renderCurrentFrame()`. When
    /// `UserDefaults.standard.string(forKey: "WPEMetalCaptureScene")` matches
    /// the active scene's workshopID, the render's `MTLCommandBuffer` is
    /// captured to a `.gputrace` file under `/tmp` so a maintainer can open
    /// it in Xcode and inspect every render-pass attachment, bound texture,
    /// uniform buffer, and translated MSL source for that scene.
    ///
    /// Triggered via:
    ///   defaults write Taijia.LiveWallpaper WPEMetalCaptureScene 3669681034
    /// (then reload the wallpaper). Clear with:
    ///   defaults delete Taijia.LiveWallpaper WPEMetalCaptureScene
    func beginGPUCaptureIfRequested() -> GPUCaptureHandle? {
        #if DEBUG
        guard gpuCaptureRequestedForCurrentScene() else { return nil }
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            Logger.info(
                "[WPEMetalCaptureScene] device does not support gpuTraceDocument capture; ensure MetalCaptureEnabled is YES in Info.plist and Xcode is attached.",
                category: .wpeRender
            )
            return nil
        }
        let descriptorObj = MTLCaptureDescriptor()
        descriptorObj.captureObject = executor.textureSourceDevice
        descriptorObj.destination = .gpuTraceDocument
        let traceURL: URL
        do {
            traceURL = try Self.makeCaptureURL(workshopID: descriptor.workshopID)
        } catch {
            Logger.info(
                "[WPEMetalCaptureScene] could not create capture directory: \(error.localizedDescription)",
                category: .wpeRender
            )
            return nil
        }
        descriptorObj.outputURL = traceURL
        do {
            try manager.startCapture(with: descriptorObj)
            Logger.notice(
                "[WPEMetalCaptureScene] capture started for \(descriptor.workshopID) → \(traceURL.path)",
                category: .wpeRender
            )
            WPESceneDebugArtifacts.shared.appendLog(
                "[capture.start] gputrace → \(traceURL.path)",
                level: .notice
            )
            return GPUCaptureHandle(manager: manager, outputURL: traceURL)
        } catch {
            Logger.info(
                "[WPEMetalCaptureScene] capture start failed: \(error.localizedDescription)",
                category: .wpeRender
            )
            return nil
        }
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static func makeCaptureURL(workshopID: String) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("gpu-traces", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = UUID().uuidString.prefix(8)
        return dir.appendingPathComponent("wpe-\(workshopID)-\(suffix).gputrace")
    }

    struct GPUCaptureHandle {
        let manager: MTLCaptureManager
        let outputURL: URL

        func stop() {
            guard manager.isCapturing else { return }
            manager.stopCapture()
            Logger.notice(
                "[WPEMetalCaptureScene] capture written → \(outputURL.path)",
                category: .wpeRender
            )
            WPESceneDebugArtifacts.shared.appendLog(
                "[capture.stop] gputrace ready at \(outputURL.path)",
                level: .notice
            )
        }
    }
    #else
    struct GPUCaptureHandle {
        func stop() {}
    }
    #endif

    // MARK: - Debug staging & frame sync

    /// One-shot debug breadcrumb shared by every load-path stage. Emits to
    /// the `wpeRender` os.Logger category AND mirrors into the per-scene
    /// `scene.log` so the file artifact stays self-contained without the
    /// reader having to cross-reference Console.app.
    /// Per-load stage breadcrumb. Gated on the scene-debug switch (Developer
    /// Tools → "Scene debug artifacts"), which is off by default — so a normal
    /// run emits none of these and, because `detail` is `@autoclosure`, never
    /// even builds the (per-stage, per-pass) interpolated strings. Flip the
    /// switch on to get the full console + scene.log stage trace back.
    func debugStage(_ stage: String, _ detail: @autoclosure () -> String) {
        guard WPESceneDebugArtifacts.shared.isEnabled else { return }
        let detail = detail()
        Logger.debug(
            "[WPE-DEBUG][scene:\(descriptor.workshopID)][stage:\(stage)] \(detail)",
            category: .wpeRender
        )
        WPESceneDebugArtifacts.shared.appendLog("[\(stage)] \(detail)")
    }

    /// Whether the executor should submit frames synchronously (block on GPU
    /// completion) for this scene. True only when a CPU read-back of the rendered
    /// frame will happen — scene-debug artifacts (first-frame snapshot / stats),
    /// GPU capture, per-pass dumps — or the operator pins it via
    /// `WPEMetalSerializeFrames`. Production has none of these, so frames submit
    /// asynchronously and the CPU never stalls on the GPU per frame.
    func shouldSynchronizeFrames() -> Bool {
        if UserDefaults.standard.bool(forKey: "WPEMetalSerializeFrames") { return true }
        if WPESceneDebugArtifacts.shared.isEnabled { return true }
        #if DEBUG
        if gpuCaptureRequestedForCurrentScene() { return true }
        if !(UserDefaults.standard.string(forKey: "WPEDumpScenePasses") ?? "").isEmpty { return true }
        #endif
        return false
    }
}
#endif
