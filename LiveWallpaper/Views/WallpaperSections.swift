#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI
import UniformTypeIdentifiers

/// Shader preset gallery embedded in `ScreenDetailPreviewArea`.
struct ShaderWallpaperSection: View {
    var screen: Screen
    @Binding var selectedShaderSource: ShaderSource
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var store = CustomShaderStore.shared
    @State private var importError: ImportErrorAlert?
    @State private var pendingDeletion: CustomShader?
    @State private var thumbnails: [String: NSImage] = [:]

    /// 256 KB is well over what a hand-written fragment shader needs (most are
    /// < 4 KB) while bounding malicious / accidentally-pasted-binary files.
    private static let maxImportBytes = 256 * 1024

    private static let presetColumns = [
        GridItem(.adaptive(minimum: 88, maximum: 140), spacing: 12, alignment: .top)
    ]

    private static let thumbnailCornerRadius: CGFloat = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                builtinSection
                customSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await store.reload()
            await loadThumbnails(for: MetalShaderPreset.allCases.map(ShaderSource.builtin))
        }
        .task(id: store.shaders.map(\.id)) {
            await loadThumbnails(for: store.shaders.map { ShaderSource.custom($0.id) })
        }
        .alert(item: $importError) { alert in
            Alert(
                title: Text("Shader Import Failed"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $pendingDeletion) { shader in
            Alert(
                title: Text("Delete Shader?"),
                message: Text("\(shader.displayName) will be removed from your library. This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) { Task { await perform(deletion: shader) } },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Sections

    private var builtinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built-in")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Self.presetColumns, spacing: 12) {
                ForEach(MetalShaderPreset.allCases) { preset in
                    presetButton(preset)
                }
            }
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Custom Shaders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: Self.presetColumns, spacing: 12) {
                ForEach(store.shaders) { shader in
                    customCard(shader)
                }
                importCard
            }

            Text("Custom shaders implement `mainImage(uv, time, resolution)` in Metal Shader Language. The file is compiled on import; errors are surfaced inline.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Cards

    /// Drives the card "selected" highlight from live runtime state rather than the draft `selectedShaderSource`, so it only lights up while a shader is actually active.
    private var activeShaderSource: ShaderSource? {
        screenManager.getConfiguration(for: screen)?.activeWallpaper.shaderSource
    }

    private func presetButton(_ preset: MetalShaderPreset) -> some View {
        let source: ShaderSource = .builtin(preset)
        let isSelected = activeShaderSource == source
        return Button {
            applyShader(source)
        } label: {
            shaderCardLabel(
                source: source,
                fallbackIcon: preset.iconName,
                title: Text(preset.titleKey),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            "\(preset.localizedTitle) shader",
            comment: "A11y label for a shader preset button. %@ = preset name (e.g. Waves)."
        ))
        .accessibilityHint(isSelected
            ? Text("Currently active. Tap again to stop.", comment: "A11y hint for the active shader card — tapping toggles it off.")
            : Text(
                "Switch to \(preset.localizedTitle) shader",
                comment: "A11y hint for a shader preset button. %@ = preset name (e.g. Waves)."
            ))
    }

    private func customCard(_ shader: CustomShader) -> some View {
        let source: ShaderSource = .custom(shader.id)
        let isSelected = activeShaderSource == source
        return Button {
            applyShader(source)
        } label: {
            shaderCardLabel(
                source: source,
                fallbackIcon: "sparkles.rectangle.stack",
                title: Text(verbatim: shader.displayName),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                pendingDeletion = shader
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel(Text(verbatim: "\(shader.displayName) (custom shader)"))
    }

    private var importCard: some View {
        Button(action: triggerImport) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.06))
                        .frame(
                            width: ShaderThumbnailRenderer.cardSize.width,
                            height: ShaderThumbnailRenderer.cardSize.height
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous)
                                .strokeBorder(
                                    Color.accentColor.opacity(0.35),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                )
                        }
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("Import")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(Text("Import a .lwshader or .metal file from disk."))
        .accessibilityLabel(Text("Import custom shader"))
    }

    private func shaderCardLabel(
        source: ShaderSource,
        fallbackIcon: String,
        title: Text,
        isSelected: Bool
    ) -> some View {
        VStack(spacing: 6) {
            thumbnailView(for: source, fallbackIcon: fallbackIcon, isSelected: isSelected)
            title
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func thumbnailView(
        for source: ShaderSource,
        fallbackIcon: String,
        isSelected: Bool
    ) -> some View {
        let size = ShaderThumbnailRenderer.cardSize
        let cornerShape = RoundedRectangle(cornerRadius: Self.thumbnailCornerRadius, style: .continuous)
        let image = thumbnails[thumbnailKey(source)]
            ?? ShaderThumbnailRenderer.shared.cachedThumbnail(
                for: source,
                pointSize: size,
                scale: max(displayScale, 1.0)
            )

        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(cornerShape)
            } else {
                cornerShape
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        Image(systemName: fallbackIcon)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .overlay {
            cornerShape
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.12),
            radius: isSelected ? 5 : 2,
            x: 0,
            y: 1
        )
    }

    // MARK: - Thumbnail loading

    private func thumbnailKey(_ source: ShaderSource) -> String {
        switch source {
        case .builtin(let preset): return "builtin:\(preset.rawValue)"
        case .custom(let id):      return "custom:\(id.uuidString)"
        }
    }

    private func loadThumbnails(for sources: [ShaderSource]) async {
        let scale = max(displayScale, 1.0)
        let size = ShaderThumbnailRenderer.cardSize
        for source in sources {
            let key = thumbnailKey(source)
            if thumbnails[key] != nil { continue }
            if let image = await ShaderThumbnailRenderer.shared.renderThumbnail(
                for: source,
                pointSize: size,
                scale: scale
            ) {
                thumbnails[key] = image
            }
        }
    }

    // MARK: - Actions

    /// First click activates; second click on the active card stops the shader
    /// (falling back to whatever else is saved, or clearing if nothing is).
    private func applyShader(_ source: ShaderSource) {
        if activeShaderSource == source {
            screenManager.clearWallpaperOfType(.metalShader, for: screen)
            return
        }
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            selectedShaderSource = source
        }
        screenManager.setShaderWallpaper(source: source, for: screen)
    }

    private func triggerImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.allowsOtherFileTypes = false
        panel.message = String(localized: "Choose a .lwshader or .metal file that defines `mainImage(uv, time, resolution)`.")
        panel.prompt = String(localized: "Import")

        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await importShader(from: url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func importShader(from url: URL) async {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Refuse oversized files before reading their contents.
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = resourceValues.fileSize, size > Self.maxImportBytes {
                importError = ImportErrorAlert(message: String(
                    localized: "Shader file is too large to import (limit \(Self.maxImportBytes / 1024) KB)."
                ))
                return
            }
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
            return
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            importError = ImportErrorAlert(message: String(localized: "Metal is not supported on this device."))
            return
        }

        // Off-main so a pathological shader can't lock the UI during import.
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try MetalWallpaperView.compileCustomShader(source: source, on: device)
            }.value
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let shader = CustomShader(name: name.isEmpty ? "Untitled" : name, source: source)
        do {
            let saved = try await store.save(shader)
            ShaderThumbnailRenderer.shared.invalidate(.custom(saved.id))
            applyShader(.custom(saved.id))
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
        }
    }

    private func perform(deletion shader: CustomShader) async {
        let wasSelected = selectedShaderSource == .custom(shader.id)
        do {
            try await store.delete(shader.id)
            ShaderThumbnailRenderer.shared.invalidate(.custom(shader.id))
            thumbnails.removeValue(forKey: thumbnailKey(.custom(shader.id)))
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
            return
        }
        if wasSelected {
            applyShader(.builtin(.waves))
        }
    }

    /// `.lwshader` is preferred; `.metal` is allowed so users can drop in stock
    /// Apple sample files; plain text is the catch-all.
    private static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .sourceCode]
        if let lwshader = UTType(filenameExtension: "lwshader") {
            types.append(lwshader)
        }
        if let metalType = UTType(filenameExtension: "metal") {
            types.append(metalType)
        }
        return types
    }()
}

/// Identifiable wrapper so `.alert(item:)` can present compile failures.
private struct ImportErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}
#endif
