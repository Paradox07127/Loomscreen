#if !LITE_BUILD
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shader preset gallery — embedded in `ScreenDetailPreviewArea` when the
/// user picks the shader wallpaper type. Renders 5 builtin presets plus the
/// user's imported `.lwshader` library; the Import button at the end of the
/// custom grid opens an `NSOpenPanel`, validates by attempting a Metal
/// compile, and either saves the entry or surfaces the diagnostic in an
/// alert. Picking any card swaps the `selectedShaderSource` binding and
/// notifies the screen manager. Each card shows a real first-frame
/// thumbnail of the shader instead of an SF Symbol so users see what they
/// are picking before they apply it.
struct ShaderWallpaperSection: View {
    var screen: Screen
    @Binding var selectedShaderSource: ShaderSource
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    @State private var store = CustomShaderStore.shared
    @State private var importError: ImportErrorAlert?
    @State private var pendingDeletion: CustomShader?

    private static let presetColumns = [
        GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 12, alignment: .top)
    ]

    private static let thumbnailCornerRadius: CGFloat = 8

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label("Shader Wallpaper", systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .semibold))

                builtinSection
                customSection
            }
            .padding(14)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
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
                primaryButton: .destructive(Text("Delete")) { perform(deletion: shader) },
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

    private func presetButton(_ preset: MetalShaderPreset) -> some View {
        let isSelected = selectedShaderSource == .builtin(preset)
        return Button {
            applyShader(.builtin(preset))
        } label: {
            shaderCardLabel(
                source: .builtin(preset),
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
            ? Text("Currently selected", comment: "A11y hint for the active shader preset button.")
            : Text(
                "Switch to \(preset.localizedTitle) shader",
                comment: "A11y hint for a shader preset button. %@ = preset name (e.g. Waves)."
            ))
    }

    private func customCard(_ shader: CustomShader) -> some View {
        let isSelected = selectedShaderSource == .custom(shader.id)
        return Button {
            applyShader(.custom(shader.id))
        } label: {
            shaderCardLabel(
                source: .custom(shader.id),
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
        let image = ShaderThumbnailRenderer.shared.thumbnail(
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

    // MARK: - Actions

    private func applyShader(_ source: ShaderSource) {
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
        panel.allowsOtherFileTypes = true
        panel.message = String(localized: "Choose a .lwshader or .metal file that defines `mainImage(uv, time, resolution)`.")
        panel.prompt = String(localized: "Import")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importShader(from: url)
    }

    private func importShader(from url: URL) {
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

        do {
            _ = try MetalWallpaperView.compileCustomShader(source: source, on: device)
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let shader = CustomShader(name: name.isEmpty ? "Untitled" : name, source: source)
        do {
            let saved = try store.save(shader)
            ShaderThumbnailRenderer.shared.invalidate(.custom(saved.id))
            applyShader(.custom(saved.id))
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
        }
    }

    private func perform(deletion shader: CustomShader) {
        let wasSelected = selectedShaderSource == .custom(shader.id)
        do {
            try store.delete(shader.id)
            ShaderThumbnailRenderer.shared.invalidate(.custom(shader.id))
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
            return
        }
        if wasSelected {
            applyShader(.builtin(.waves))
        }
    }

    /// Content types accepted by the importer. `.lwshader` is our preferred
    /// extension; `.metal` is allowed so users can drop in stock Apple sample
    /// files; plain text is the catch-all.
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

/// Identifiable wrapper so `.alert(item:)` can present compile failures
/// without needing a separate Bool+String pair.
private struct ImportErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}
#endif
