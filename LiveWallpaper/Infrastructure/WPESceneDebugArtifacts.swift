#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore

/// Per-scene debug session that mirrors every shader compile + pipeline build
/// failure to disk under `~/Library/.../Application Support/LiveWallpaper/scene-debug/<timestamp-id>/`,
/// so a maintainer can reproduce the crash with the exact preprocessed source
/// the compiler saw (original/processed GLSL, translated MSL, error text,
/// scene-info, scene.log mirror, optional first-frame.png).
///
/// Always on in DEBUG; in Release gated by the `WPESceneDebugArtifactsEnabled`
/// UserDefaults flag (Developer Mode → Developer Tools).
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
    }

    private var session: ActiveSession?
    private let sessionLock = NSLock()
    private let writeQueue = DispatchQueue(label: "wpe.scene.debug.artifacts", qos: .utility)
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return f
    }()

    /// Disabled in tests by default; the corpus harness flips it on
    /// explicitly when it wants per-scene dumps.
    var isEnabled: Bool {
        #if DEBUG
        return UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
        #else
        return UserDefaults.standard.bool(forKey: Self.defaultsKey)
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

    /// Opens a fresh session folder for the given workshop ID. Closes any
    /// prior session implicitly. No-op when `isEnabled == false`.
    @discardableResult
    func beginSession(workshopID: String, descriptor: String) -> URL? {
        guard isEnabled else { return nil }
        guard let root = Self.rootURL else { return nil }

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
            passCounter: 0
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

    /// Drop the current session reference. Files stay on disk.
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

    /// Dump a failed shader compile or pipeline build.
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

    /// Record a pipeline state build failure (color/depth/blend descriptor
    /// could not be turned into an `MTLRenderPipelineState`).
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

    /// Persist the first rendered frame (or last-known snapshot) so the
    /// orientation / tile-split / blank-screen bugs that don't trigger a
    /// shader error are visible without re-running the scene.
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

    /// Dump a pass's processed vertex+fragment source as it goes out
    /// over the WebGL bridge. Used for black-screen forensics when the
    /// pipeline loads successfully but produces wrong pixels — gives us
    /// the exact GLSL string GL receives, including the Swift prelude
    /// + include expansion + combo defines.
    func dumpRawPassSource(passID: String, shader: String, source: String) {
        guard isEnabled else { return }
        sessionLock.lock()
        let folderURL = session?.folderURL
        sessionLock.unlock()
        guard let folderURL else { return }
        let passesFolder = folderURL.appendingPathComponent("pass-source", isDirectory: true)
        let baseName = safeFileName("\(passID)-\(shader)")
        let url = passesFolder.appendingPathComponent("\(baseName).glsl")
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: passesFolder, withIntermediateDirectories: true)
                try source.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Logger.warning(
                    "Scene debug pass-source dump failed: \(error)",
                    category: .wpeRender
                )
            }
        }
    }

    /// Drop a simple text payload (named-FBO miss list, texture diagnostics,
    /// etc.) into the current session folder.
    func recordNote(name: String, contents: String) {
        guard isEnabled else { return }
        sessionLock.lock()
        let folderURL = session?.folderURL
        sessionLock.unlock()
        guard let folderURL else { return }
        write(contents, to: folderURL.appendingPathComponent(safeFileName(name)))
    }

    /// P3 dump for raw `.tex` metadata: TEXI image-dimension + unkInt0 and
    /// TEXB v4 conditional-mip fields the decoder records but the runtime
    /// doesn't act on. Lets corpus regressions cross-reference padded
    /// atlas sizes / v4 conditions against the published engine without
    /// re-reading the .tex container by hand.
    ///
    /// Writes one `tex-meta-<name>.txt` per call into the active session
    /// folder when debug artifacts are enabled; no-op otherwise.
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
