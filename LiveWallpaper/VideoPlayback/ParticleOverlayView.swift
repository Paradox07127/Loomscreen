import AppKit
import SpriteKit

/// A transparent SpriteKit-based overlay that renders particle effects
/// (snow, rain, bokeh, fireflies, falling leaves) on top of the video wallpaper.
final class ParticleOverlayView: NSView {

    // MARK: - Properties

    private let skView: SKView
    private let scene: SKScene
    private var currentEmitter: SKEmitterNode?
    private var currentEffect: ParticleEffect = .none

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        skView = SKView(frame: NSRect(origin: .zero, size: frameRect.size))
        scene = SKScene(size: frameRect.size)

        super.init(frame: frameRect)

        configureSKView()
        configureScene()
        addSubview(skView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureSKView() {
        skView.allowsTransparency = true
        skView.preferredFramesPerSecond = 30
        skView.ignoresSiblingOrder = true
        skView.autoresizingMask = [.width, .height]

        // Transparent background so the video shows through.
        skView.wantsLayer = true
        skView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func configureScene() {
        scene.backgroundColor = .clear
        scene.scaleMode = .resizeFill
        skView.presentScene(scene)
    }

    // MARK: - Public API

    /// Sets the active particle effect. Pass `.none` to remove all particles.
    func setEffect(_ effect: ParticleEffect) {
        guard effect != currentEffect else { return }
        currentEffect = effect

        // Remove existing emitter.
        currentEmitter?.removeFromParent()
        currentEmitter = nil

        guard effect != .none else { return }

        let emitter = makeEmitter(for: effect)
        // Position the emitter at the top-center for effects that fall,
        // or at the center for effects that float.
        switch effect {
        case .snow, .rain, .fallingLeaves:
            emitter.position = CGPoint(x: scene.size.width / 2, y: scene.size.height)
            emitter.particlePositionRange = CGVector(dx: scene.size.width * 1.2, dy: 0)
        case .bokeh:
            emitter.position = CGPoint(x: scene.size.width / 2, y: 0)
            emitter.particlePositionRange = CGVector(dx: scene.size.width, dy: scene.size.height * 0.2)
        case .fireflies:
            emitter.position = CGPoint(x: scene.size.width / 2, y: scene.size.height / 2)
            emitter.particlePositionRange = CGVector(dx: scene.size.width, dy: scene.size.height)
        case .none:
            break
        }

        scene.addChild(emitter)
        currentEmitter = emitter
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        skView.frame = bounds
        scene.size = bounds.size

        // Re-position the emitter for the new size.
        guard let emitter = currentEmitter else { return }
        switch currentEffect {
        case .snow, .rain, .fallingLeaves:
            emitter.position = CGPoint(x: bounds.width / 2, y: bounds.height)
            emitter.particlePositionRange = CGVector(dx: bounds.width * 1.2, dy: 0)
        case .bokeh:
            emitter.position = CGPoint(x: bounds.width / 2, y: 0)
            emitter.particlePositionRange = CGVector(dx: bounds.width, dy: bounds.height * 0.2)
        case .fireflies:
            emitter.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            emitter.particlePositionRange = CGVector(dx: bounds.width, dy: bounds.height)
        case .none:
            break
        }
    }

    // MARK: - Emitter Factory

    private func makeEmitter(for effect: ParticleEffect) -> SKEmitterNode {
        switch effect {
        case .snow:       return makeSnowEmitter()
        case .rain:       return makeRainEmitter()
        case .bokeh:      return makeBokehEmitter()
        case .fireflies:  return makeFirefliesEmitter()
        case .fallingLeaves: return makeFallingLeavesEmitter()
        case .none:       return SKEmitterNode()  // should not be called
        }
    }

    // MARK: Snow

    private func makeSnowEmitter() -> SKEmitterNode {
        let emitter = SKEmitterNode()

        // Use a small white circle texture.
        emitter.particleTexture = SKTexture(image: makeCircleImage(radius: 4, color: .white))

        emitter.particleBirthRate = 40
        emitter.numParticlesToEmit = 0  // infinite
        emitter.particleLifetime = 10
        emitter.particleLifetimeRange = 4

        emitter.particleSpeed = 30
        emitter.particleSpeedRange = 20
        emitter.emissionAngle = -.pi / 2    // straight down
        emitter.emissionAngleRange = .pi / 8

        emitter.particleScale = 0.8
        emitter.particleScaleRange = 0.5

        emitter.particleAlpha = 0.8
        emitter.particleAlphaRange = 0.2

        // Slight horizontal drift.
        emitter.xAcceleration = 5
        emitter.yAcceleration = -10

        emitter.particleColor = .white
        emitter.particleBlendMode = .alpha

        return emitter
    }

    // MARK: Rain

    private func makeRainEmitter() -> SKEmitterNode {
        let emitter = SKEmitterNode()

        // Thin vertical streak.
        emitter.particleTexture = SKTexture(image: makeStreakImage(width: 1, height: 12, color: NSColor.white.withAlphaComponent(0.5)))

        emitter.particleBirthRate = 100
        emitter.numParticlesToEmit = 0
        emitter.particleLifetime = 3
        emitter.particleLifetimeRange = 1

        emitter.particleSpeed = 400
        emitter.particleSpeedRange = 100
        emitter.emissionAngle = -.pi / 2
        emitter.emissionAngleRange = .pi / 30  // nearly straight down

        emitter.particleScale = 1.0
        emitter.particleScaleRange = 0.3

        emitter.particleAlpha = 0.4
        emitter.particleAlphaRange = 0.2

        emitter.yAcceleration = -200

        emitter.particleColor = .white
        emitter.particleBlendMode = .alpha

        return emitter
    }

    // MARK: Bokeh

    private func makeBokehEmitter() -> SKEmitterNode {
        let emitter = SKEmitterNode()

        // Large soft circle.
        emitter.particleTexture = SKTexture(image: makeCircleImage(radius: 20, color: .white))

        emitter.particleBirthRate = 5
        emitter.numParticlesToEmit = 0
        emitter.particleLifetime = 12
        emitter.particleLifetimeRange = 4

        emitter.particleSpeed = 15
        emitter.particleSpeedRange = 10
        emitter.emissionAngle = .pi / 2    // upward
        emitter.emissionAngleRange = .pi / 4

        emitter.particleScale = 0.5
        emitter.particleScaleRange = 0.4

        emitter.particleAlpha = 0.15
        emitter.particleAlphaRange = 0.1
        emitter.particleAlphaSpeed = -0.01

        // Gentle upward float.
        emitter.yAcceleration = 5
        emitter.xAcceleration = 2

        emitter.particleColorBlendFactor = 1.0
        emitter.particleColor = NSColor(calibratedRed: 1, green: 0.9, blue: 0.7, alpha: 1)
        emitter.particleColorRedRange = 0.2
        emitter.particleColorGreenRange = 0.2
        emitter.particleColorBlueRange = 0.3
        emitter.particleBlendMode = .add

        return emitter
    }

    // MARK: Fireflies

    private func makeFirefliesEmitter() -> SKEmitterNode {
        let emitter = SKEmitterNode()

        // Tiny bright dot.
        emitter.particleTexture = SKTexture(image: makeCircleImage(radius: 3, color: .white))

        emitter.particleBirthRate = 8
        emitter.numParticlesToEmit = 0
        emitter.particleLifetime = 6
        emitter.particleLifetimeRange = 3

        emitter.particleSpeed = 10
        emitter.particleSpeedRange = 15
        emitter.emissionAngle = 0
        emitter.emissionAngleRange = .pi * 2  // all directions

        emitter.particleScale = 0.6
        emitter.particleScaleRange = 0.3

        // Pulsing alpha via alpha speed oscillation.
        emitter.particleAlpha = 0.8
        emitter.particleAlphaRange = 0.4
        emitter.particleAlphaSpeed = -0.15

        // Random movement via small accelerations.
        emitter.xAcceleration = 0
        emitter.yAcceleration = 3

        emitter.particleColor = NSColor(calibratedRed: 1, green: 1, blue: 0.6, alpha: 1)
        emitter.particleColorBlendFactor = 1.0
        emitter.particleBlendMode = .add

        return emitter
    }

    // MARK: Falling Leaves

    private func makeFallingLeavesEmitter() -> SKEmitterNode {
        let emitter = SKEmitterNode()

        // Medium leaf-like shape (we use a circle with scale distortion as a stand-in).
        emitter.particleTexture = SKTexture(image: makeLeafImage(size: CGSize(width: 12, height: 8)))

        emitter.particleBirthRate = 8
        emitter.numParticlesToEmit = 0
        emitter.particleLifetime = 14
        emitter.particleLifetimeRange = 6

        emitter.particleSpeed = 25
        emitter.particleSpeedRange = 15
        emitter.emissionAngle = -.pi / 2   // downward
        emitter.emissionAngleRange = .pi / 6

        emitter.particleScale = 1.0
        emitter.particleScaleRange = 0.5

        emitter.particleAlpha = 0.7
        emitter.particleAlphaRange = 0.2

        // Swaying side-to-side via rotation + horizontal acceleration.
        emitter.particleRotation = 0
        emitter.particleRotationRange = .pi
        emitter.particleRotationSpeed = 0.5

        emitter.xAcceleration = 15
        emitter.yAcceleration = -8

        emitter.particleColor = NSColor(calibratedRed: 0.85, green: 0.6, blue: 0.2, alpha: 1)
        emitter.particleColorBlendFactor = 1.0
        emitter.particleColorRedRange = 0.15
        emitter.particleColorGreenRange = 0.2
        emitter.particleBlendMode = .alpha

        return emitter
    }

    // MARK: - Texture Helpers

    /// Creates a simple filled-circle NSImage for use as a particle texture.
    private func makeCircleImage(radius: CGFloat, color: NSColor) -> NSImage {
        let size = CGSize(width: radius * 2, height: radius * 2)
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw a soft radial gradient for a glow effect.
        let gradient = NSGradient(
            starting: color.withAlphaComponent(1.0),
            ending: color.withAlphaComponent(0.0)
        )
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        gradient?.draw(in: path, relativeCenterPosition: .zero)

        image.unlockFocus()
        return image
    }

    /// Creates a thin vertical streak for rain particles.
    private func makeStreakImage(width: CGFloat, height: CGFloat, color: NSColor) -> NSImage {
        let size = CGSize(width: max(width, 2), height: height)
        let image = NSImage(size: size)
        image.lockFocus()

        color.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: width / 2, yRadius: width / 2).fill()

        image.unlockFocus()
        return image
    }

    /// Creates a simple leaf-shaped image.
    private func makeLeafImage(size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: size.height / 2))
        path.curve(
            to: CGPoint(x: size.width, y: size.height / 2),
            controlPoint1: CGPoint(x: size.width * 0.3, y: size.height),
            controlPoint2: CGPoint(x: size.width * 0.7, y: size.height)
        )
        path.curve(
            to: CGPoint(x: 0, y: size.height / 2),
            controlPoint1: CGPoint(x: size.width * 0.7, y: 0),
            controlPoint2: CGPoint(x: size.width * 0.3, y: 0)
        )
        path.close()

        NSColor(calibratedRed: 0.85, green: 0.6, blue: 0.2, alpha: 1.0).setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    // MARK: - Cleanup

    deinit {
        currentEmitter?.removeFromParent()
        skView.presentScene(nil)
    }
}
