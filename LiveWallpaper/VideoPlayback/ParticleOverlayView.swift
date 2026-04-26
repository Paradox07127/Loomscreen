import AppKit
import QuartzCore

/// A layer-hosting NSView whose backing layer is a `CAEmitterLayer`.
///
/// ## Why CAEmitterLayer (not SpriteKit)
///
/// The previous implementation wrapped an `SKView` (SpriteKit) inside an NSView
/// and tried to compose it above an `AVPlayerLayer` sibling. That fails in
/// practice on macOS because `SKView`'s backing layer is a `CAMetalLayer` with
/// its own off-tree render pass — when both `CAMetalLayer` and `AVPlayerLayer`
/// live as siblings under a layer-backed parent, AppKit's composition order
/// becomes implementation-defined and the particle layer ends up rendered
/// behind the video.
///
/// `CAEmitterLayer` is a plain `CALayer` subclass that participates in normal
/// Core Animation compositing, so it composites cleanly above an
/// `AVPlayerLayer` sibling using deterministic NSView subview ordering.
///
/// ## Coordinate System
///
/// The default macOS `CALayer` uses **bottom-left origin** (y increases up),
/// matching NSView's default. So `(0, 0)` is bottom-left, `(width, height)`
/// is top-right. "Falling from the sky" particles emit at `y = bounds.height`
/// with negative y-velocity / negative `yAcceleration`.
final class ParticleOverlayView: NSView {

    // MARK: - State

    private var currentEffect: ParticleEffect = .none
    private var currentDensity: CGFloat = 1.0

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

    /// Switches the active particle effect. Pass `.none` to disable particles.
    /// `density` is a multiplier on the emitter's master birth rate (0.05–3.0
    /// effective). Density-only updates do not rebuild the cells, so existing
    /// particles continue their lifecycle smoothly.
    func setEffect(_ effect: ParticleEffect, density: CGFloat = 1.0) {
        if effect == currentEffect {
            updateDensity(density)
            return
        }

        currentEffect = effect
        currentDensity = density

        // Remove old emitter immediately. CAEmitterLayer already lets in-flight
        // particles live out their `lifetime` even after the layer is removed
        // from the tree, so the visual transition is smooth without any
        // asyncAfter delay. Removing immediately also prevents sublayer
        // accumulation if the user switches effects rapidly.
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
        currentDensity = density
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
            cell.xAcceleration = 10 * scale // Wind affects closer particles more
            cell.yAcceleration = -15 * scale // Gravity
            cell.color = NSColor(white: 1, alpha: CGFloat(alpha)).cgColor
            return cell
        }

        let near = createLayer(1.2, 50, 10, 0.6, 6.0) // Large, soft, out-of-focus
        let mid = createLayer(0.6, 30, 30, 0.8, 3.0)  // Medium, sharp
        let far = createLayer(0.3, 15, 60, 0.4, 2.0)  // Small, slow, dense

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
        // Soft continuous drizzle — small round droplets falling straight down.
        //
        // Why round (not streak): a 2×16 streak texture made the rain look
        // wind-blown because fast-moving elongated shapes read visually as
        // "motion lines" even when travelling straight. A round droplet has
        // no orientation so velocity direction is unambiguous.
        //
        // Why velocity = 0: the initial velocity vector used `emissionLongitude`
        // which appeared to introduce a small horizontal drift. With velocity
        // zero, direction is governed purely by gravity (`yAcceleration`),
        // guaranteeing a straight-down path.
        let cell = CAEmitterCell()
        cell.contents = ParticleTextures.softCircle(
            radius: 2.5,
            color: NSColor.white.withAlphaComponent(0.7).cgColor
        )
        cell.birthRate = 260            // dense, steady drizzle
        cell.lifetime = 5
        cell.lifetimeRange = 1
        cell.velocity = 0               // start at rest — gravity does all the work
        cell.velocityRange = 0
        cell.emissionLongitude = 0
        cell.emissionRange = 0
        cell.scale = 0.9
        cell.scaleRange = 0.3
        cell.alphaRange = 0.25
        cell.yAcceleration = -160       // gentle gravity for a slow fall
        cell.xAcceleration = 0          // no wind
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
        // Bokeh is the photography effect of out-of-focus highlights appearing
        // as soft glowing orbs. We emit multiple cells with different warm /
        // cool / pastel colors spread across the whole screen, using additive
        // blending to get the signature dreamy glow.
        let palette: [CGColor] = [
            NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.70, alpha: 0.85).cgColor, // warm amber
            NSColor(calibratedRed: 0.70, green: 0.88, blue: 1.00, alpha: 0.85).cgColor, // cool blue
            NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.90, alpha: 0.85).cgColor, // pink
            NSColor(calibratedRed: 0.85, green: 1.00, blue: 0.85, alpha: 0.85).cgColor, // mint
        ]
        let cells = palette.map { color -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: 32, color: color)
            cell.birthRate = 0.9      // ~3.6 orbs/sec across all 4 cells — sparse by default
            cell.lifetime = 9
            cell.lifetimeRange = 3
            cell.velocity = 6         // very slow drift
            cell.velocityRange = 8
            cell.emissionRange = .pi * 2  // random direction — orbs float freely
            cell.scale = 1.0
            cell.scaleRange = 0.6
            cell.scaleSpeed = 0.04    // slow growth (emulates depth-of-field pull)
            cell.alphaRange = 0.2
            cell.alphaSpeed = -0.09   // fade out over lifetime
            cell.yAcceleration = 3    // gentle upward rise
            cell.color = color
            return cell
        }
        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .additive,
            // Spawn over the entire screen so orbs are always visible across
            // the whole frame instead of rising from a single edge.
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Fireflies

    private static let firefliesPreset: EmitterPreset = {
        // 之前 radius=3 + scale=0.8 渲染 ~5px 的小亮点，被视频内容完全淹没。
        // 把贴图放大到 radius=14 + scale=1.0–1.4，并提高 birthRate 让萤火虫
        // 在画面里有真正的辉光感；color 用浅黄绿模拟夜光昆虫色温。
        let glowColor = NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.55, alpha: 1).cgColor
        let cell = CAEmitterCell()
        cell.contents = ParticleTextures.softCircle(radius: 14, color: glowColor)
        cell.birthRate = 30
        cell.lifetime = 8
        cell.lifetimeRange = 3
        cell.velocity = 18
        cell.velocityRange = 22
        cell.emissionRange = .pi * 2  // all directions
        cell.scale = 1.0
        cell.scaleRange = 0.4
        cell.alphaRange = 0.6
        cell.alphaSpeed = -0.12  // 缓慢淡出制造闪烁
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
            NSColor(calibratedRed: 0.85, green: 0.4, blue: 0.1, alpha: 1).cgColor, // Orange
            NSColor(calibratedRed: 0.9, green: 0.7, blue: 0.1, alpha: 1).cgColor,  // Yellow
            NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.1, alpha: 1).cgColor   // Brown
        ]
        
        var cells: [CAEmitterCell] = []
        for (i, color) in palette.enumerated() {
            let scaleMultiplier = CGFloat(1.0 - Float(i) * 0.25) // Parallax depth mapping
            
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
            cell.xAcceleration = 20 * scaleMultiplier // Wind affects foreground more
            cell.yAcceleration = -10 * scaleMultiplier // Gravity
            cell.color = color
            
            cells.append(cell)
        }

        return EmitterPreset(
            cells: cells,
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX - $0.width * 0.2, y: $0.maxY) }, // Offset for wind drift
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
            cell.xAcceleration = 25 * scale // persistent soft breeze to the right
            cell.yAcceleration = -12 * scale // light gravity
            cell.color = NSColor(cgColor: baseColor)!.withAlphaComponent(CGFloat(alpha)).cgColor
            
            // Add slight color variation per petal
            cell.redRange = 0.1
            cell.greenRange = 0.1
            cell.blueRange = 0.1
            
            return cell
        }

        let near = createLayer(1.4, 55, 6, 0.7, 4.0)   // Large foreground petals
        let mid = createLayer(0.9, 40, 15, 0.9, 0.0)   // Standard petals
        let far = createLayer(0.5, 25, 30, 0.5, -4.0)  // Small background drift

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX - $0.width * 0.3, y: $0.maxY) }, // Start further left to drift right across screen
            size: { CGSize(width: $0.width * 1.6, height: 0) }
        )
    }()
}

// MARK: - Particle Texture Factory
//
// CAEmitterCell.contents expects a `CGImage`. We build them with
// CGBitmapContext directly — the older NSImage.lockFocus +
// cgImage(forProposedRect:context:hints:) path silently returned nil in many
// cases on macOS, which is why particle cells used to render nothing even
// though the emitter was correctly configured.

private enum ParticleTextures {

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Creates a `CGContext` suitable for drawing a particle texture.
    /// Returns nil only if the bitmap allocation actually fails.
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

    /// Soft radial-gradient circle, white-to-transparent. Used for snow,
    /// bokeh, fireflies — any particle that wants a glow falloff.
    static func softCircle(radius: CGFloat, color: CGColor) -> CGImage? {
        let diameter = max(Int(ceil(radius * 2)), 2)
        guard let ctx = makeContext(width: diameter, height: diameter) else { return nil }

        let center = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        let endRadius = CGFloat(diameter) / 2

        // Build a 2-stop radial gradient that fades to transparent.
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

    /// Cherry-blossom petal — a soft teardrop shape with a gentle notch at the
    /// tip, drawn with a radial gradient to give subtle depth.
    static func sakuraPetal(width: CGFloat, height: CGFloat, color: CGColor) -> CGImage? {
        let w = max(Int(ceil(width)), 2)
        let h = max(Int(ceil(height)), 2)
        guard let ctx = makeContext(width: w, height: h) else { return nil }

        let widthF = CGFloat(w)
        let heightF = CGFloat(h)

        // Build a teardrop using two symmetric bezier curves. Origin is
        // bottom-left in the CG context.
        let path = CGMutablePath()
        let tipX = widthF / 2
        path.move(to: CGPoint(x: tipX, y: 0))                    // narrow tip at bottom
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: heightF),                    // rounded top
            control: CGPoint(x: widthF * 1.15, y: heightF * 0.5)
        )
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: 0),                          // back to tip
            control: CGPoint(x: -widthF * 0.15, y: heightF * 0.5)
        )
        path.closeSubpath()

        // Clip to the petal path, then draw a radial gradient to get a soft
        // center-bright / edge-soft look.
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
            // Fallback to flat fill if gradient construction fails.
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

    /// Simple leaf shape — a flattened ellipse with two pointed ends.
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
