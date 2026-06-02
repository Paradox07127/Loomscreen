#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

struct WPEMSDFTextPageDraw {
    let page: Int
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let texture: MTLTexture
}

struct WPEMSDFTextDrawPayload {
    let pages: [WPEMSDFTextPageDraw]
    let uniforms: [String: WPESceneShaderConstantValue]
    let combos: [String: Int]
    let shaderRequest: WPEShaderCompileRequest
}

@MainActor
final class WPEMSDFTextRenderer {
    private let device: MTLDevice
    private let resolver: WPEMultiRootResourceResolver
    private let fontFragmentSource: String
    private let parameters: WPEMSDFParameters
    private let atlas: WPEMSDFAtlas
    private let generator: WPEMSDFGlyphGenerator
    private let layout = WPEMSDFTextLayout()
    private var registeredFonts: Set<String> = []

    init(
        device: MTLDevice,
        resolver: WPEMultiRootResourceResolver,
        fontFragmentSource: String,
        parameters: WPEMSDFParameters = WPEMSDFParameters()
    ) {
        self.device = device
        self.resolver = resolver
        self.fontFragmentSource = fontFragmentSource
        self.parameters = parameters
        self.atlas = WPEMSDFAtlas(device: device)
        self.generator = WPEMSDFGlyphGenerator(parameters: parameters)
    }

    func drawPayload(
        for object: WPESceneTextObject,
        sceneSize: CGSize,
        parallaxOffset: SIMD2<Float>
    ) -> WPEMSDFTextDrawPayload? {
        let font = resolveFont(for: object)
        let material = WPEMSDFFontMaterial.make(object: object, parameters: parameters)
        guard let request = try? shaderRequest(comboValues: material.combos) else { return nil }
        guard let mesh = layout.layout(
            object: object,
            font: font,
            atlas: atlas,
            generator: generator
        ) else { return nil }

        let transformed = transform(mesh: mesh, object: object, parallaxOffset: parallaxOffset)
        let pages = transformed.perPage.keys.sorted().compactMap { page -> WPEMSDFTextPageDraw? in
            guard let vertices = transformed.perPage[page], !vertices.isEmpty,
                  let texture = atlas.texture(page: page) else {
                return nil
            }
            let buffer = vertices.withUnsafeBytes { rawBuffer -> MTLBuffer? in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                return device.makeBuffer(bytes: baseAddress, length: rawBuffer.count, options: [])
            }
            guard let buffer else { return nil }
            return WPEMSDFTextPageDraw(
                page: page,
                vertexBuffer: buffer,
                vertexCount: vertices.count,
                texture: texture
            )
        }
        guard pages.count == transformed.perPage.count, !pages.isEmpty else { return nil }
        _ = sceneSize
        return WPEMSDFTextDrawPayload(
            pages: pages,
            uniforms: material.uniforms,
            combos: material.combos,
            shaderRequest: request
        )
    }

    private func transform(
        mesh: WPEMSDFTextMesh,
        object: WPESceneTextObject,
        parallaxOffset: SIMD2<Float>
    ) -> WPEMSDFTextMesh {
        let scale = SIMD2<Double>(
            max(object.scale.x, 0.0001),
            max(object.scale.y, 0.0001)
        )
        let scaledSize = SIMD2<Double>(
            Double(mesh.size.width) * scale.x,
            Double(mesh.size.height) * scale.y
        )
        let topLeft = SIMD2<Double>(
            object.origin.x + Double(parallaxOffset.x) - scaledSize.x * 0.5,
            object.origin.y + Double(parallaxOffset.y) - scaledSize.y * 0.5
        )
        var transformed: [Int: [WPEMSDFTextVertex]] = [:]
        for (page, vertices) in mesh.perPage {
            transformed[page] = vertices.map { vertex in
                let local = SIMD2<Double>(Double(vertex.position.x), Double(vertex.position.y))
                return WPEMSDFTextVertex(
                    position: SIMD2<Float>(
                        Float(topLeft.x + local.x * scale.x),
                        Float(topLeft.y + local.y * scale.y)
                    ),
                    uv: vertex.uv
                )
            }
        }
        return WPEMSDFTextMesh(perPage: transformed, size: mesh.size)
    }

    private func shaderRequest(comboValues: [String: Int]) throws -> WPEShaderCompileRequest {
        let processor = WPEShaderPreprocessor { [resolver] path, _ in
            Self.readInclude(path: path, resolver: resolver)
        }
        return try processor.process(
            shaderName: "font",
            vertexSource: Self.vertexStub,
            fragmentSource: fontFragmentSource,
            comboValues: comboValues,
            materialTextureBindings: [:]
        )
    }

    private func resolveFont(for object: WPESceneTextObject) -> CTFont {
        font(for: object, size: effectiveFontSize(for: object))
    }

    /// The scene's font (custom file or HelveticaNeue fallback) at an explicit
    /// size. Used both for the final glyph font and for box measurement, so
    /// box-fit is computed with the SAME typeface that will be rendered.
    private func font(for object: WPESceneTextObject, size: CGFloat) -> CTFont {
        if let path = object.fontRelativePath {
            registerFontIfNeeded(path)
            if let url = try? resolver.resolveExistingFileURL(relativePath: path),
               let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let descriptor = descriptors.first {
                return CTFontCreateWithFontDescriptor(descriptor, size, nil)
            }
        }
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    private func registerFontIfNeeded(_ path: String) {
        guard !registeredFonts.contains(path) else { return }
        registeredFonts.insert(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { return }
        var unmanagedError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        unmanagedError?.release()
    }

    private func effectiveFontSize(for object: WPESceneTextObject) -> CGFloat {
        let base = CGFloat(max(object.pointSize, 1))
        guard let box = object.boxSize, box.x > 0, box.y > 0 else { return base }
        let font = font(for: object, size: base)
        let attributed = CFAttributedStringCreate(nil, object.text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = max(CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)), 0.5)
        let height = max(ascent + descent + leading, 0.5)
        let innerW = max(CGFloat(box.x - 2 * object.padding), 1)
        let innerH = max(CGFloat(box.y - 2 * object.padding), 1)
        let fit = min(innerW / width, innerH / height)
        guard fit.isFinite, fit > 0 else { return base }
        return base * fit
    }

    private static func readInclude(path: String, resolver: WPEMultiRootResourceResolver) -> String? {
        let candidates = path.hasPrefix("shaders/") ? [path] : ["shaders/\(path)", path]
        for candidate in candidates {
            guard let url = try? resolver.resolveExistingFileURL(relativePath: candidate),
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            return text
        }
        return nil
    }

    private static let vertexStub = """
    #version 410 core
    void main() {}
    """
}
#endif
