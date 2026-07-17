#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Per-scene debug session that mirrors shader compile + pipeline build failures
/// to disk under `Application Support/LiveWallpaper/scene-debug/<timestamp-id>/`,
/// so a maintainer can reproduce the crash with the exact preprocessed source the
/// compiler saw (original/processed GLSL, translated MSL, error text, first-frame.png).
///
/// Gated by the `WPESceneDebugArtifactsEnabled` UserDefaults flag, off by default so
/// a normal launch never pays for dumps / read-back / binding diagnostics; the
/// Developer Tools toggle and trace tests flip it on explicitly.
///
/// `@unchecked Sendable`: `session` is guarded by `sessionLock`; I/O via `writeQueue`.
final class WPESceneDebugArtifacts: @unchecked Sendable {

    static let shared = WPESceneDebugArtifacts()

    static let defaultsKey = "WPESceneDebugArtifactsEnabled"

    private struct ActiveSession {
        let workshopID: String
        let folderURL: URL
        let logURL: URL
        var passCounter: Int
        var noteNames: Set<String>
    }

    private var session: ActiveSession?
    private let sessionLock = NSLock()
    private let writeQueue = DispatchQueue(label: "wpe.scene.debug.artifacts", qos: .utility)
    private let bindingDiagnosticsLock = NSLock()
    private var bindingDiagnostics: [String] = []
    private let maxBindingDiagnostics = 512

    #if DEBUG
    private let testingEnabledOverrideLock = NSLock()
    private var testingEnabledOverride: Bool?

    /// Forces `isEnabled` independent of UserDefaults so trace tests don't depend on
    /// the developer's `WPESceneDebugArtifactsEnabled` setting. Pass nil to clear.
    func setEnabledForTesting(_ enabled: Bool?) {
        testingEnabledOverrideLock.lock()
        testingEnabledOverride = enabled
        testingEnabledOverrideLock.unlock()
    }
    #endif

    /// Caps so dump-enabled builds don't accumulate unbounded PNG/MSL artifacts.
    /// Oldest folders pruned first when either bound is exceeded; newest always kept.
    private let maxSessionFolders = 40
    private let maxTotalBytes: UInt64 = 512 * 1024 * 1024  // 512 MiB
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return f
    }()

    /// DEBUG-only: hard-disabled in Release so a stray `WPESceneDebugArtifactsEnabled`
    /// flag (e.g. from `defaults write` or an imported settings bundle) can never make
    /// a shipping build write first-frame snapshots / scene-debug dumps. Disabled by
    /// default even in DEBUG; the Developer Tools toggle flips it on for per-scene dumps.
    var isEnabled: Bool {
        #if DEBUG
        testingEnabledOverrideLock.lock()
        let testingOverride = testingEnabledOverride
        testingEnabledOverrideLock.unlock()
        if let testingOverride { return testingOverride }
        // The render oracle needs the canonical trace recorder to run, so enabling
        // oracle mode implies artifacts are enabled (no need to set both defaults).
        return UserDefaults.standard.bool(forKey: Self.defaultsKey) || WPEOracleMode.isEnabled
        #else
        return false
        #endif
    }

    static var rootURL: URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let root = support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("scene-debug", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        } catch {
            Logger.warning(
                "Scene debug root unavailable: \(error)",
                category: .wpeRender
            )
            return nil
        }
    }

    /// Closes any prior session implicitly. No-op when `isEnabled == false`.
    @discardableResult
    func beginSession(workshopID: String, descriptor: String) -> URL? {
        guard isEnabled else { return nil }
        guard let root = Self.rootURL else { return nil }
        pruneOldSessions(under: root)

        let stamp = compactTimestamp(from: Date())
        let folder = root.appendingPathComponent("\(stamp)-\(workshopID)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Logger.warning(
                "Scene debug session create failed: \(error)",
                category: .wpeRender
            )
            return nil
        }

        let logURL = folder.appendingPathComponent("scene.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        sessionLock.lock()
        session = ActiveSession(
            workshopID: workshopID,
            folderURL: folder,
            logURL: logURL,
            passCounter: 0,
            noteNames: []
        )
        sessionLock.unlock()

        let info = """
        workshopID: \(workshopID)
        opened: \(ISO8601DateFormatter().string(from: Date()))
        descriptor: \(descriptor)
        """
        write(info, to: folder.appendingPathComponent("scene-info.txt"))

        Logger.notice(
            "Scene debug session opened at \(folder.path)",
            category: .wpeRender
        )
        return folder
    }

    /// Async on the write queue so it never blocks scene load. Best-effort —
    /// failures ignored, and the single newest session is always retained.
    private func pruneOldSessions(under root: URL) {
        let maxFolders = maxSessionFolders
        let maxBytes = maxTotalBytes
        writeQueue.async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }

            // Newest first, so we keep the most recent sessions and trim the tail.
            let folders = children
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { url -> (url: URL, date: Date, size: UInt64) in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return (url, date, Self.directorySize(of: url, fm: fm))
                }
                .sorted { $0.date > $1.date }

            var runningBytes: UInt64 = 0
            for (index, folder) in folders.enumerated() {
                runningBytes += folder.size
                let overCount = index + 1 > maxFolders
                let overBytes = index > 0 && runningBytes > maxBytes
                if overCount || overBytes {
                    try? fm.removeItem(at: folder.url)
                }
            }
        }
    }

    private static func directorySize(of url: URL, fm: FileManager) -> UInt64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            total += UInt64(size)
        }
        return total
    }

    /// Drops the session reference; files stay on disk.
    func endSession() {
        sessionLock.lock()
        let workshopID = session?.workshopID
        session = nil
        sessionLock.unlock()
        if let workshopID {
            Logger.notice(
                "Scene debug session closed for \(workshopID)",
                category: .wpeRender
            )
        }
    }

    /// Append a single line to the per-scene log (in addition to the global
    /// runtime.log mirror Logger already handles).
    func appendLog(_ message: String, level: Logger.Level = .info) {
        guard isEnabled else { return }
        sessionLock.lock()
        let url = session?.logURL
        sessionLock.unlock()
        guard let url else { return }
        let prefix = "[\(ISO8601DateFormatter().string(from: Date()))][\(levelTag(level))]"
        let line = "\(prefix) \(message)\n"
        writeQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Kept lightweight and bounded because DEBUG builds may record it every frame.
    func recordTextureBinding(
        passID: String,
        shader: String,
        slot: Int,
        reference: WPETextureReference?,
        texture: MTLTexture?,
        fallbackToPrimary: Bool
    ) {
        guard isEnabled else { return }
        let event = "[binding] pass=\(passID) shader=\(shader) slot=\(slot) reference=\(textureReferenceDescription(reference)) texture=\(textureDescription(texture)) fallback=\(fallbackToPrimary)"
        bindingDiagnosticsLock.lock()
        bindingDiagnostics.append(event)
        if bindingDiagnostics.count > maxBindingDiagnostics {
            bindingDiagnostics.removeFirst(bindingDiagnostics.count - maxBindingDiagnostics)
        }
        bindingDiagnosticsLock.unlock()
        appendLog(event, level: fallbackToPrimary ? .warning : .debug)
    }

    func recordPassList(_ pipeline: WPEPreparedRenderPipeline) {
        guard isEnabled else { return }
        var lines: [String] = []
        for (layerIndex, layer) in pipeline.layers.enumerated() {
            lines.append("layer[\(layerIndex)] id=\(layer.graphLayer.objectID) name=\(layer.graphLayer.objectName)")
            for pass in layer.passes {
                let textures = pass.textureBindings
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(textureReferenceDescription($0.value))" }
                    .joined(separator: ",")
                lines.append(
                    "  pass=\(pass.pass.id) shader=\(pass.pass.shader) source=\(textureReferenceDescription(pass.pass.source)) target=\(targetDescription(pass.pass.target)) blend=\(pass.pass.blending) textures=[\(textures)]"
                )
            }
        }
        recordNote(name: "pass-list.txt", contents: lines.joined(separator: "\n"))
        appendLog("[pass-list] wrote \(pipeline.layers.reduce(0) { $0 + $1.passes.count }) pass entries")
        recordLayerPlacements(pipeline)
    }

    /// Latest puppet skinning-gate state per objectID, pushed by the render executor every frame and
    /// merged into the layer-placements dump so a bug-report dump shows why a puppet fell back to the
    /// rest pose. Placements are recorded at pipeline build — before the first frame resolves the
    /// gate — so a puppet line reads `skinning=pending` until a state stamped with the CURRENT
    /// placements generation arrives; a state from a previous pipeline renders as
    /// `pending(last=…)` instead of masquerading as current (a reload can reuse an objectID for a
    /// different puppet, and a failed first frame must not leave the old verdict standing).
    private let layerPlacementsLock = NSLock()
    private struct PuppetSkinningEntry {
        let generation: Int
        let summary: String
    }
    private var puppetSkinningByObjectID: [String: PuppetSkinningEntry] = [:]
    private var layerPlacementsGeneration = 0
    private struct LayerPlacementLine {
        let puppetObjectID: String?
        let text: String
    }
    private var layerPlacementLines: [LayerPlacementLine] = []

    /// Called once per rendered frame with EVERY puppet's current gate state (executor-side logging
    /// dedupes separately). Cheap when nothing changed: re-stamping an unchanged summary only
    /// rewrites the note when it moves a stale entry to the current generation, and only summaries
    /// that actually changed reach the scene-debug log.
    func recordPuppetSkinningStates(_ states: [(objectID: String, summary: String)]) {
        guard isEnabled, !states.isEmpty else { return }
        layerPlacementsLock.lock()
        let generation = layerPlacementsGeneration
        var changedSummaries: [(String, String)] = []
        var needsRewrite = false
        for (objectID, summary) in states {
            let existing = puppetSkinningByObjectID[objectID]
            guard existing?.generation != generation || existing?.summary != summary else { continue }
            puppetSkinningByObjectID[objectID] = PuppetSkinningEntry(generation: generation, summary: summary)
            needsRewrite = true
            if existing?.summary != summary {
                changedSummaries.append((objectID, summary))
            }
        }
        let hasPlacements = !layerPlacementLines.isEmpty
        layerPlacementsLock.unlock()
        for (objectID, summary) in changedSummaries {
            appendLog("[puppet-skin] id=\(objectID) skinning=\(summary)")
        }
        if needsRewrite, hasPlacements { writeLayerPlacementsNote() }
    }

    /// Dumps layer placements + puppet MDAT anchors so a body-split rig's
    /// parent/child mis-placement can be diagnosed numerically.
    func recordLayerPlacements(_ pipeline: WPEPreparedRenderPipeline) {
        guard isEnabled else { return }
        func fmt(_ v: SIMD3<Double>) -> String { String(format: "(%.1f,%.1f,%.1f)", v.x, v.y, v.z) }
        func fmt2(_ v: SIMD2<Double>) -> String { String(format: "(%.1f,%.1f)", v.x, v.y) }
        var lines: [LayerPlacementLine] = []
        var puppetObjectIDs: Set<String> = []
        for layer in pipeline.layers {
            let g = layer.graphLayer.geometry
            let sizeStr = g.size.map { String(format: "%.0fx%.0f", $0.width, $0.height) } ?? "nil"
            let isPuppet = layer.puppetModel != nil
            if isPuppet { puppetObjectIDs.insert(layer.graphLayer.objectID) }
            lines.append(LayerPlacementLine(
                puppetObjectID: isPuppet ? layer.graphLayer.objectID : nil,
                text: "id=\(layer.graphLayer.objectID) name=\(layer.graphLayer.objectName) "
                    + "puppet=\(isPuppet ? 1 : 0) "
                    + "parent=\(layer.graphLayer.parentObjectID ?? "-") attach=\(layer.graphLayer.attachment ?? "-") "
                    + "origin=\(fmt(g.origin)) size=\(sizeStr) meshCenter=\(fmt2(g.puppetMeshCenter)) "
                    + "scale=\(fmt(g.scale)) angles=\(fmt(g.angles)) align=\(g.alignment)"
            ))
            if let model = layer.puppetModel, !model.attachments.isEmpty {
                for a in model.attachments {
                    let bind = a.bindMatrix
                    let bt = bind.count >= 16 ? String(format: "MDAT_T=(%.1f,%.1f)", bind[12], bind[13]) : "MDAT_T=?"
                    let bone = model.bones.first { $0.index == a.boneIndex }
                    let bw = bone.flatMap { $0.rawMatrix.count >= 16 ? $0.rawMatrix : nil }
                    let bwt = bw.map { String(format: "boneWorld_T=(%.1f,%.1f)", $0[12], $0[13]) } ?? "boneWorld_T=?"
                    lines.append(LayerPlacementLine(
                        puppetObjectID: nil,
                        text: "    anchor \(a.name) -> bone \(a.boneIndex)  \(bt)  \(bwt)"
                    ))
                }
            }
        }
        layerPlacementsLock.lock()
        layerPlacementLines = lines
        // A new pipeline starts a new generation: every gate state must be re-proven by the next
        // rendered frame before it renders as current. Entries for objectIDs no longer present are
        // dropped outright.
        layerPlacementsGeneration += 1
        puppetSkinningByObjectID = puppetSkinningByObjectID.filter { puppetObjectIDs.contains($0.key) }
        layerPlacementsLock.unlock()
        writeLayerPlacementsNote()
        appendLog("[placements] wrote \(pipeline.layers.count) layer placements")
    }

    private func writeLayerPlacementsNote() {
        recordNote(name: "layer-placements.txt", contents: renderedLayerPlacementsContents())
    }

    /// Exposed for tests via `layerPlacementsContentsForTesting`.
    private func renderedLayerPlacementsContents() -> String {
        layerPlacementsLock.lock()
        let lines = layerPlacementLines
        let skinning = puppetSkinningByObjectID
        let generation = layerPlacementsGeneration
        layerPlacementsLock.unlock()
        let rendered = lines.map { line -> String in
            guard let id = line.puppetObjectID else { return line.text }
            guard let entry = skinning[id] else { return line.text + " skinning=pending" }
            return entry.generation == generation
                ? line.text + " skinning=\(entry.summary)"
                : line.text + " skinning=pending(last=\(entry.summary))"
        }
        return rendered.joined(separator: "\n")
    }

    func layerPlacementsContentsForTesting() -> String {
        renderedLayerPlacementsContents()
    }

    func recordFirstFrameStats(_ stats: WPEMetalTextureVisualStats) {
        guard isEnabled else { return }
        recordNote(name: "first-frame-stats.txt", contents: stats.description)
        appendLog("[frame.stats] \(stats.oneLineDescription)")
    }

    func recordResolutionSummary(_ snapshot: WPEResolutionDiagnosticsSnapshot) {
        guard isEnabled else { return }
        let counts = snapshot.resolvedByOrigin
        let dependencyCount = counts.reduce(0) { partial, entry in
            if case .dependency = entry.key { return partial + entry.value }
            return partial
        }
        var lines: [String] = [
            "events: \(snapshot.events.count)",
            "resolved: \(snapshot.resolvedCount)",
            "missing: \(snapshot.missedRefs.count)",
            "scene: \(counts[.scene, default: 0])",
            "builtin: \(counts[.builtin, default: 0])",
            "engineAssets: \(counts[.engineAssets, default: 0])",
            "dependency: \(dependencyCount)"
        ]
        if !snapshot.missedRefs.isEmpty {
            lines.append("misses:")
            lines.append(contentsOf: snapshot.missedRefs.prefix(40).map {
                "  \($0.ref) -> \($0.finalOutcome.debugLabel)"
            })
        }
        recordNote(name: "resolution-summary.txt", contents: lines.joined(separator: "\n"))
        appendLog(
            "[resolution] events=\(snapshot.events.count) resolved=\(snapshot.resolvedCount) missing=\(snapshot.missedRefs.count)"
        )
    }

    func drainBindingDiagnosticsForTesting() -> [String] {
        bindingDiagnosticsLock.lock()
        defer { bindingDiagnosticsLock.unlock() }
        let current = bindingDiagnostics
        bindingDiagnostics.removeAll(keepingCapacity: true)
        return current
    }

    func recordShaderFailure(
        shaderName: String,
        originalVertex: String?,
        processedVertex: String?,
        originalFragment: String?,
        processedFragment: String?,
        translatedMSL: String?,
        errorText: String
    ) {
        guard isEnabled else { return }

        sessionLock.lock()
        guard var current = session else {
            sessionLock.unlock()
            return
        }
        current.passCounter += 1
        let passIndex = current.passCounter
        let folderURL = current.folderURL
        session = current
        sessionLock.unlock()

        let folderName = String(format: "%03d-%@", passIndex, safeFileName(shaderName))
        let dir = folderURL
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Logger.warning(
                "Scene debug shader dir create failed: \(error)",
                category: .wpeRender
            )
            return
        }

        if let originalVertex {
            write(originalVertex, to: dir.appendingPathComponent("01-vertex-original.glsl"))
        }
        if let processedVertex {
            write(processedVertex, to: dir.appendingPathComponent("02-vertex-processed.glsl"))
        }
        if let originalFragment {
            write(originalFragment, to: dir.appendingPathComponent("03-fragment-original.glsl"))
        }
        if let processedFragment {
            write(processedFragment, to: dir.appendingPathComponent("04-fragment-processed.glsl"))
        }
        if let translatedMSL {
            write(translatedMSL, to: dir.appendingPathComponent("05-msl-translated.msl"))
        }
        write(errorText, to: dir.appendingPathComponent("06-error.txt"))

        Logger.error(
            "Shader '\(shaderName)' compile failure dumped → \(dir.path) — \(firstLine(of: errorText))",
            category: .wpeRender
        )
        appendLog("[shader fail] '\(shaderName)' → shaders/\(folderName)/  \(firstLine(of: errorText))", level: .error)
    }

    func recordPipelineFailure(
        fragmentName: String,
        blendMode: String,
        detail: String
    ) {
        guard isEnabled else { return }
        sessionLock.lock()
        guard let current = session else {
            sessionLock.unlock()
            return
        }
        let folderURL = current.folderURL
        let counter = current.passCounter
        sessionLock.unlock()

        let dir = folderURL.appendingPathComponent("pipelines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = String(
            format: "%03d-%@-%@.err",
            counter + 1,
            safeFileName(fragmentName),
            safeFileName(blendMode)
        )
        write(detail, to: dir.appendingPathComponent(filename))
        Logger.error(
            "Pipeline '\(fragmentName)' (blend=\(blendMode)) build failed: \(firstLine(of: detail))",
            category: .wpeRender
        )
        appendLog("[pipeline fail] '\(fragmentName)' blend=\(blendMode) → pipelines/\(filename)", level: .error)
    }

    /// Persists the first frame so orientation / tile-split / blank-screen bugs
    /// that don't trigger a shader error are visible without re-running the scene.
    func recordFirstFrame(image: NSImage) {
        guard isEnabled else { return }
        sessionLock.lock()
        let folderURL = session?.folderURL
        sessionLock.unlock()
        guard let folderURL else { return }
        let url = folderURL.appendingPathComponent("first-frame.png")
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            Logger.warning(
                "Scene debug first-frame snapshot failed (no PNG representation)",
                category: .wpeRender
            )
            return
        }
        do {
            try png.write(to: url, options: .atomic)
            Logger.notice(
                "Scene debug first frame saved → \(url.path)",
                category: .wpeRender
            )
        } catch {
            Logger.warning(
                "Scene debug first-frame write failed: \(error)",
                category: .wpeRender
            )
        }
    }

    func recordNote(name: String, contents: String) {
        guard isEnabled else { return }
        sessionLock.lock()
        let folderURL = session?.folderURL
        sessionLock.unlock()
        guard let folderURL else { return }
        write(contents, to: folderURL.appendingPathComponent(safeFileName(name)))
    }

    /// Writes once per session — for successful shader dumps that would
    /// otherwise be rewritten every rendered frame.
    func recordNoteOnce(name: String, contents: String) {
        guard isEnabled else { return }
        let safeName = safeFileName(name)
        sessionLock.lock()
        guard var current = session else {
            sessionLock.unlock()
            return
        }
        guard current.noteNames.insert(safeName).inserted else {
            sessionLock.unlock()
            return
        }
        let folderURL = current.folderURL
        session = current
        sessionLock.unlock()
        write(contents, to: folderURL.appendingPathComponent(safeName))
    }

    /// Dumps raw `.tex` metadata: TEXI image-dimension + unkInt0 and TEXB v4
    /// conditional-mip fields the decoder records but the runtime doesn't act on.
    /// Lets corpus regressions cross-reference padded atlas sizes / v4 conditions
    /// against the published engine without re-reading the .tex container by hand.
    func dumpRawTexMetadata(name: String, info: WPETexInfo, bitmap: WPETexBitmapBlock) {
        guard isEnabled else { return }
        var lines: [String] = []
        lines.append("container=\(info.containerVersion) infoVersion=\(info.infoVersion)")
        lines.append("size=\(info.width)x\(info.height) imageSize=\(info.imageWidth)x\(info.imageHeight) unkInt0=\(info.unknownInt0)")
        let formatLabel = info.format?.debugLabel ?? "unknown(\(info.textureFormatCode))"
        lines.append("format=\(formatLabel) flags=0x\(String(info.flags, radix: 16))")
        let sourceFormat = bitmap.sourceImageFormatCode?.description ?? "nil"
        lines.append("bitmapVersion=\(bitmap.version) sourceImageFormatCode=\(sourceFormat) isVideo=\(bitmap.isVideoPayload) usesEncoded=\(bitmap.usesEncodedImagePayload)")
        lines.append("frames=\(bitmap.frames.count)")
        for (frameIndex, mipmaps) in bitmap.frames.enumerated() {
            for mipmap in mipmaps {
                var line = "  frame=\(frameIndex) mip=\(mipmap.index) size=\(mipmap.width)x\(mipmap.height) stored=\(mipmap.storedByteCount) compressed=\(mipmap.isCompressed)"
                if let decompressed = mipmap.decompressedByteCount {
                    line += " decompressed=\(decompressed)"
                }
                if let v4 = mipmap.v4Fields {
                    line += " v4{p1=\(v4.param1) p2=\(v4.param2) cond=\"\(v4.condition)\" p3=\(v4.param3)}"
                }
                lines.append(line)
            }
        }
        recordNote(name: "tex-meta-\(name).txt", contents: lines.joined(separator: "\n"))
    }

    var activeSessionFolder: URL? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session?.folderURL
    }

    // MARK: - Helpers

    private func write(_ contents: String, to url: URL) {
        writeQueue.async {
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Logger.warning(
                    "Scene debug write failed for \(url.lastPathComponent): \(error)",
                    category: .wpeRender
                )
            }
        }
    }

    private func compactTimestamp(from date: Date) -> String {
        let raw = isoFormatter.string(from: date)
        return raw
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "T", with: "-")
    }

    private func safeFileName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>| \t\n")
        return raw
            .components(separatedBy: illegal)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    private func textureReferenceDescription(_ reference: WPETextureReference?) -> String {
        guard let reference else { return "<primary>" }
        switch reference {
        case .image(let path):
            return "image(\(path))"
        case .asset(let path):
            return "asset(\(path))"
        case .fbo(let name):
            return "fbo(\(name))"
        case .previous:
            return "previous"
        }
    }

    private func targetDescription(_ target: WPERenderTarget) -> String {
        switch target {
        case .scene:
            return "scene"
        case .layerComposite(let name):
            return "layerComposite(\(name))"
        case .fbo(let name):
            return "fbo(\(name))"
        }
    }

    private func textureDescription(_ texture: MTLTexture?) -> String {
        guard let texture else { return "nil" }
        if let label = texture.label, !label.isEmpty {
            return label
        }
        return "\(texture.width)x\(texture.height):\(texture.pixelFormat.rawValue)"
    }

    private func levelTag(_ level: Logger.Level) -> String {
        switch level {
        case .debug:    return "DEBUG"
        case .info:     return "INFO"
        case .notice:   return "NOTICE"
        case .warning:  return "WARNING"
        case .error:    return "ERROR"
        case .fault:    return "FAULT"
        }
    }
}
#endif
