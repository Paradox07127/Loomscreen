import AppKit
import LiveWallpaperCore
import QuartzCore

final class ParticleOverlayView: NSView {

    // MARK: - State

    private var currentEffect: ParticleEffect = .none

    private var activeEmitter: CAEmitterLayer?

    // MARK: - Layer Hosting

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.clear.cgColor
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    func setEffect(_ effect: ParticleEffect, density: CGFloat = 1.0) {
        if effect == currentEffect {
            updateDensity(density)
            return
        }

        currentEffect = effect

        if let oldEmitter = activeEmitter {
            oldEmitter.birthRate = 0
            oldEmitter.removeFromSuperlayer()
            activeEmitter = nil
        }

        guard effect != .none else { return }

        let emitter = CAEmitterLayer()
        emitter.emitterMode = .surface
        emitter.backgroundColor = NSColor.clear.cgColor
        emitter.frame = bounds

        let preset = preset(for: effect)
        emitter.emitterCells = preset.cells
        emitter.emitterShape = preset.shape
        emitter.renderMode = preset.renderMode
        emitter.emitterPosition = preset.position(bounds)
        emitter.emitterSize = preset.size(bounds)
        emitter.birthRate = Float(max(0.05, density))

        layer?.addSublayer(emitter)
        activeEmitter = emitter
    }

    func updateDensity(_ density: CGFloat) {
        activeEmitter?.birthRate = Float(max(0.05, density))
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let emitter = activeEmitter, currentEffect != .none else { return }
        emitter.frame = bounds
        let preset = preset(for: currentEffect)
        emitter.emitterPosition = preset.position(bounds)
        emitter.emitterSize = preset.size(bounds)
    }

    // MARK: - Effect Presets

    private struct EmitterPreset {
        let cells: [CAEmitterCell]
        let shape: CAEmitterLayerEmitterShape
        let renderMode: CAEmitterLayerRenderMode
        let position: (CGRect) -> CGPoint
        let size: (CGRect) -> CGSize
    }

    private func preset(for effect: ParticleEffect) -> EmitterPreset {
        switch effect {
        case .none:          return Self.emptyPreset
        case .snow:          return Self.snowPreset
        case .rain:          return Self.rainPreset
        case .bokeh:         return Self.bokehPreset
        case .fireflies:     return Self.firefliesPreset
        case .dust:          return Self.dustPreset
        case .stars:         return Self.starsPreset
        case .fallingLeaves: return Self.leavesPreset
        case .sakura:        return Self.sakuraPreset
        }
    }

    private static let emptyPreset = EmitterPreset(
        cells: [],
        shape: .point,
        renderMode: .unordered,
        position: { _ in .zero },
        size: { _ in .zero }
    )

    // MARK: - Snow

    private static let snowPreset: EmitterPreset = {
        let createLayer = { (scale: CGFloat, velocity: CGFloat, birthRate: Float, alpha: Float, radius: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: radius, color: NSColor.white.cgColor)
            cell.birthRate = birthRate
            cell.lifetime = 15
            cell.lifetimeRange = 5
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.3
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 8
            cell.scale = scale
            cell.scaleRange = scale * 0.3
            cell.alphaRange = alpha * 0.3
            cell.xAcceleration = 10 * scale
            cell.yAcceleration = -15 * scale
            cell.color = NSColor(white: 1, alpha: CGFloat(alpha)).cgColor
            return cell
        }

        let near = createLayer(1.2, 50, 10, 0.6, 6.0)
        let mid = createLayer(0.6, 30, 30, 0.8, 3.0)
        let far = createLayer(0.3, 15, 60, 0.4, 2.0)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            size: { CGSize(width: $0.width * 1.5, height: 0) }
        )
    }()

    // MARK: - Rain

    private static let rainPreset: EmitterPreset = {
        let cell = CAEmitterCell()
        cell.contents = ParticleTextures.softCircle(
            radius: 2.5,
            color: NSColor.white.withAlphaComponent(0.7).cgColor
        )
        cell.birthRate = 260
        cell.lifetime = 5
        cell.lifetimeRange = 1
        cell.velocity = 0
        cell.velocityRange = 0
        cell.emissionLongitude = 0
        cell.emissionRange = 0
        cell.scale = 0.9
        cell.scaleRange = 0.3
        cell.alphaRange = 0.25
        cell.yAcceleration = -160
        cell.xAcceleration = 0
        cell.color = NSColor(white: 1.0, alpha: 0.75).cgColor
        return EmitterPreset(
            cells: [cell],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            size: { CGSize(width: $0.width * 1.1, height: 0) }
        )
    }()

    // MARK: - Bokeh

    private static let bokehPreset: EmitterPreset = {
        let palette: [CGColor] = [
            NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.70, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 0.70, green: 0.88, blue: 1.00, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.90, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 0.85, green: 1.00, blue: 0.85, alpha: 0.85).cgColor,
        ]
        let cells = palette.map { color -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: 32, color: color)
            cell.birthRate = 0.9
            cell.lifetime = 9
            cell.lifetimeRange = 3
            cell.velocity = 6
            cell.velocityRange = 8
            cell.emissionRange = .pi * 2
            cell.scale = 1.0
            cell.scaleRange = 0.6
            cell.scaleSpeed = 0.04
            cell.alphaRange = 0.2
            cell.alphaSpeed = -0.09
            cell.yAcceleration = 3
            cell.color = color
            return cell
        }
        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Fireflies

    private static let firefliesPreset: EmitterPreset = {
        let glowColor = NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.55, alpha: 1).cgColor
        let cell = CAEmitterCell()
        cell.contents = ParticleTextures.softCircle(radius: 14, color: glowColor)
        cell.birthRate = 30
        cell.lifetime = 8
        cell.lifetimeRange = 3
        cell.velocity = 18
        cell.velocityRange = 22
        cell.emissionRange = .pi * 2
        cell.scale = 1.0
        cell.scaleRange = 0.4
        cell.alphaRange = 0.6
        cell.alphaSpeed = -0.12
        cell.yAcceleration = 2
        cell.color = glowColor
        return EmitterPreset(
            cells: [cell],
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Falling Leaves

    private static let leavesPreset: EmitterPreset = {
        let palette: [CGColor] = [
            NSColor(calibratedRed: 0.85, green: 0.4, blue: 0.1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.9, green: 0.7, blue: 0.1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.1, alpha: 1).cgColor
        ]
        
        var cells: [CAEmitterCell] = []
        for (i, color) in palette.enumerated() {
            let scaleMultiplier = CGFloat(1.0 - Float(i) * 0.25)
            
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.leaf(width: 14, height: 9, color: NSColor.white.cgColor)
            cell.birthRate = 8 * Float(i + 1)
            cell.lifetime = 16
            cell.lifetimeRange = 8
            cell.velocity = 35 * scaleMultiplier
            cell.velocityRange = 20 * scaleMultiplier
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 4
            cell.scale = 1.2 * scaleMultiplier
            cell.scaleRange = 0.4 * scaleMultiplier
            cell.alphaRange = 0.3
            cell.spin = 1.5
            cell.spinRange = 2.0
            cell.xAcceleration = 20 * scaleMultiplier
            cell.yAcceleration = -10 * scaleMultiplier
            cell.color = color
            
            cells.append(cell)
        }

        return EmitterPreset(
            cells: cells,
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX - $0.width * 0.2, y: $0.maxY) },
            size: { CGSize(width: $0.width * 1.5, height: 0) }
        )
    }()

    // MARK: - Sakura

    private static let sakuraPreset: EmitterPreset = {
        let baseColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.82, alpha: 1.0).cgColor
        
        let createLayer = { (scale: CGFloat, velocity: CGFloat, birthRate: Float, alpha: Float, sizeOffset: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.sakuraPetal(width: 16 + sizeOffset, height: 14 + sizeOffset, color: NSColor.white.cgColor)
            cell.birthRate = birthRate
            cell.lifetime = 15
            cell.lifetimeRange = 5
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.4
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 4
            cell.scale = scale
            cell.scaleRange = scale * 0.3
            cell.alphaRange = alpha * 0.3
            cell.spin = 1.0
            cell.spinRange = 2.0
            cell.xAcceleration = 25 * scale
            cell.yAcceleration = -12 * scale
            cell.color = baseColor.copy(alpha: CGFloat(alpha)) ?? baseColor
            
            cell.redRange = 0.1
            cell.greenRange = 0.1
            cell.blueRange = 0.1
            
            return cell
        }

        let near = createLayer(1.4, 55, 6, 0.7, 4.0)
        let mid = createLayer(0.9, 40, 15, 0.9, 0.0)
        let far = createLayer(0.5, 25, 30, 0.5, -4.0)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX - $0.width * 0.3, y: $0.maxY) },
            size: { CGSize(width: $0.width * 1.6, height: 0) }
        )
    }()

    // MARK: - Dust
    //
    // Sun-shaft motes: tiny warm specks drifting in all directions with a
    // very slow lift. Three depth layers (near / mid / far) so it reads as
    // volumetric rather than a flat sprite sheet.

    private static let dustPreset: EmitterPreset = {
        let warmColor = NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.78, alpha: 1.0).cgColor
        let createLayer = { (radius: CGFloat, scale: CGFloat, birthRate: Float, alpha: Float, velocity: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: radius, color: warmColor)
            cell.birthRate = birthRate
            cell.lifetime = 18
            cell.lifetimeRange = 6
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.6
            cell.emissionRange = .pi * 2
            cell.scale = scale
            cell.scaleRange = scale * 0.5
            cell.alphaRange = alpha * 0.4
            cell.alphaSpeed = -0.02
            cell.yAcceleration = -1.5
            cell.xAcceleration = 0.5
            cell.color = warmColor.copy(alpha: CGFloat(alpha)) ?? warmColor
            return cell
        }

        let near = createLayer(3.0, 1.3, 4, 0.7, 8)
        let mid  = createLayer(2.0, 0.9, 10, 0.5, 6)
        let far  = createLayer(1.4, 0.5, 18, 0.3, 4)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Stars
    //
    // Nearly stationary points with strong alpha-pulse so the field reads
    // as a slow twinkle. Cool palette (white-blue) sits well against night
    // wallpapers without forcing a specific color theme.

    private static let starsPreset: EmitterPreset = {
        let warmWhite = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.92, alpha: 1.0).cgColor
        let coolBlue = NSColor(calibratedRed: 0.85, green: 0.92, blue: 1.0, alpha: 1.0).cgColor

        let createLayer = { (radius: CGFloat, scale: CGFloat, birthRate: Float, color: CGColor) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: radius, color: color)
            cell.birthRate = birthRate
            cell.lifetime = 10
            cell.lifetimeRange = 4
            cell.velocity = 0
            cell.velocityRange = 0.5
            cell.emissionRange = .pi * 2
            cell.scale = scale
            cell.scaleRange = scale * 0.4
            cell.alphaRange = 0.45
            cell.alphaSpeed = -0.15
            cell.color = color
            return cell
        }

        let bright = createLayer(3.5, 1.2, 6, warmWhite)
        let mid    = createLayer(2.5, 0.8, 12, coolBlue)
        let faint  = createLayer(1.5, 0.5, 20, coolBlue)

        return EmitterPreset(
            cells: [bright, mid, faint],
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

}

// MARK: - Particle Texture Factory
//
// CAEmitterCell needs CGImage textures; CGBitmapContext is reliable here.

private enum ParticleTextures {

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        return CGContext(
            data: nil,
            width: max(width, 1),
            height: max(height, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func softCircle(radius: CGFloat, color: CGColor) -> CGImage? {
        let diameter = max(Int(ceil(radius * 2)), 2)
        guard let ctx = makeContext(width: diameter, height: diameter) else { return nil }

        let center = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        let endRadius = CGFloat(diameter) / 2

        guard let opaqueColor = color.copy(alpha: 1.0),
              let transparent = color.copy(alpha: 0.0),
              let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [opaqueColor, transparent] as CFArray,
                locations: [0.0, 1.0]
              )
        else { return nil }

        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: endRadius,
            options: []
        )

        return ctx.makeImage()
    }

    static func sakuraPetal(width: CGFloat, height: CGFloat, color: CGColor) -> CGImage? {
        let w = max(Int(ceil(width)), 2)
        let h = max(Int(ceil(height)), 2)
        guard let ctx = makeContext(width: w, height: h) else { return nil }

        let widthF = CGFloat(w)
        let heightF = CGFloat(h)

        let path = CGMutablePath()
        let tipX = widthF / 2
        path.move(to: CGPoint(x: tipX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: heightF),
            control: CGPoint(x: widthF * 1.15, y: heightF * 0.5)
        )
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: 0),
            control: CGPoint(x: -widthF * 0.15, y: heightF * 0.5)
        )
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()

        guard let lightColor = color.copy(alpha: 1.0),
              let edgeColor = color.copy(alpha: 0.55),
              let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [lightColor, edgeColor] as CFArray,
                locations: [0.0, 1.0]
              )
        else {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: widthF, height: heightF))
            return ctx.makeImage()
        }

        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: widthF * 0.5, y: heightF * 0.6),
            startRadius: 0,
            endCenter: CGPoint(x: widthF * 0.5, y: heightF * 0.5),
            endRadius: max(widthF, heightF),
            options: []
        )
        return ctx.makeImage()
    }

    static func leaf(width: CGFloat, height: CGFloat, color: CGColor) -> CGImage? {
        let w = max(Int(ceil(width)), 2)
        let h = max(Int(ceil(height)), 2)
        guard let ctx = makeContext(width: w, height: h) else { return nil }

        let widthF = CGFloat(w)
        let heightF = CGFloat(h)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: heightF / 2))
        path.addCurve(
            to: CGPoint(x: widthF, y: heightF / 2),
            control1: CGPoint(x: widthF * 0.3, y: heightF),
            control2: CGPoint(x: widthF * 0.7, y: heightF)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: heightF / 2),
            control1: CGPoint(x: widthF * 0.7, y: 0),
            control2: CGPoint(x: widthF * 0.3, y: 0)
        )
        path.closeSubpath()

        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        return ctx.makeImage()
    }
}
