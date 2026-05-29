#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal

struct WPEMetalTextureResolution: Equatable, Sendable {
    let textureWidth: Int
    let textureHeight: Int
    let imageWidth: Int
    let imageHeight: Int

    init(texture: MTLTexture, imageWidth: Int? = nil, imageHeight: Int? = nil) {
        textureWidth = max(texture.width, 1)
        textureHeight = max(texture.height, 1)
        self.imageWidth = max(Self.validLogicalSize(imageWidth) ?? texture.width, 1)
        self.imageHeight = max(Self.validLogicalSize(imageHeight) ?? texture.height, 1)
    }

    var shaderValue: WPESceneShaderConstantValue {
        .vector([
            Double(textureWidth),
            Double(textureHeight),
            Double(imageWidth),
            Double(imageHeight)
        ])
    }

    private static func validLogicalSize(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }
        return value
    }
}

final class WPEMetalTextureMetadataRegistry: @unchecked Sendable {
    static let shared = WPEMetalTextureMetadataRegistry()

    private final class Entry {
        weak var texture: MTLTexture?
        let resolution: WPEMetalTextureResolution

        init(texture: MTLTexture, resolution: WPEMetalTextureResolution) {
            self.texture = texture
            self.resolution = resolution
        }
    }

    private let lock = NSLock()
    private var resolutions: [ObjectIdentifier: Entry] = [:]

    private init() {}

    func register(texture: MTLTexture, imageWidth: Int? = nil, imageHeight: Int? = nil) {
        let key = ObjectIdentifier(texture as AnyObject)
        let resolution = WPEMetalTextureResolution(
            texture: texture,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        lock.lock()
        resolutions[key] = Entry(texture: texture, resolution: resolution)
        lock.unlock()
    }

    func resolution(for texture: MTLTexture) -> WPEMetalTextureResolution {
        let key = ObjectIdentifier(texture as AnyObject)
        lock.lock()
        if let entry = resolutions[key],
           let registeredTexture = entry.texture,
           ObjectIdentifier(registeredTexture as AnyObject) == key {
            let resolution = entry.resolution
            lock.unlock()
            return resolution
        }
        if resolutions[key] != nil {
            resolutions.removeValue(forKey: key)
        }
        lock.unlock()
        return WPEMetalTextureResolution(texture: texture)
    }
}
#endif
