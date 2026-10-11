import AppKit
import QuartzCore
import WeatherglassCore

/// A lightning flash that lights the whole screen for a moment.
@MainActor
final class LightningLayer: CAGradientLayer {
    override init() {
        super.init()
        type = .radial
        colors = [CGColor(red: 0.92, green: 0.95, blue: 1, alpha: 0.9), CGColor(red: 0.8, green: 0.86, blue: 1, alpha: 0.15)]
        locations = [0, 1]
        opacity = 0
        actions = ["opacity": NSNull(), "startPoint": NSNull(), "endPoint": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// - Parameter strength: 0...1, how bright the brightest flicker gets.
    func flash(strength: Float, at x: CGFloat) {
        startPoint = CGPoint(x: x, y: 1.05)
        endPoint = CGPoint(x: x + 0.9, y: -0.4)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        let s = strength
        a.values = [0, 0.55 * s, 0.08 * s, 0.38 * s, 0.02 * s, 0.22 * s, 0]
        a.keyTimes = [0, 0.04, 0.1, 0.16, 0.3, 0.38, 1]
        a.duration = 0.9
        add(a, forKey: "flash")
    }
}

/// Fog drifting across the screen, thickest at the edges, like a cold window.
@MainActor
final class FogLayer: CALayer {
    private var built = false
    private let fade = CAGradientLayer()

    override init() {
        super.init()
        opacity = 0
        actions = ["opacity": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(fog: Double) {
        let target = fog > 0 ? Float(0.35 + 0.65 * min(fog, 1)) : 0
        if target > 0 && !built { build() }
        guard abs(target - opacity) > 0.01 else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = presentation()?.opacity ?? opacity
        a.toValue = target
        a.duration = 3
        opacity = target
        add(a, forKey: "fade")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        if built, fade.frame != bounds { rebuild() }
    }

    private func rebuild() {
        sublayers?.forEach { $0.removeFromSuperlayer() }
        built = false
        build()
    }

    private func build() {
        let size = bounds.size
        guard size.width > 0 else { return }
        built = true
        let content = CALayer()
        content.frame = bounds
        addSublayer(content)
        // Thicker toward the edges and bottom, thinner in the middle where you read.
        fade.type = .radial
        fade.frame = bounds
        fade.colors = [CGColor(gray: 0, alpha: 0.35), CGColor(gray: 0, alpha: 1)]
        fade.locations = [0.15, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0.55)
        fade.endPoint = CGPoint(x: 1.15, y: 1.25)
        content.mask = fade

        let d = max(size.width, size.height) * 0.75
        for i in 0..<7 {
            let puff = CALayer()
            let image = Sprites.fogPuff(512, seed: i)
            puff.contents = image
            puff.bounds = CGRect(x: 0, y: 0, width: d, height: d * 0.6)
            let y = size.height * CGFloat([0.08, 0.3, 0.55, 0.85, 0.15, 0.7, 0.45][i])
            let x = size.width * CGFloat([0.1, 0.9, 0.2, 0.75, 0.6, 0.35, 0.05][i])
            puff.position = CGPoint(x: x, y: y)
            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = x - size.width * 0.18
            drift.toValue = x + size.width * 0.18
            drift.duration = Double.random(in: 70...130)
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timeOffset = Double.random(in: 0...60)
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            puff.add(drift, forKey: "drift")
            content.addSublayer(puff)
        }
    }
}

/// Leaves (or spring petals) blown across the screen on windy days.
///
/// Each leaf is its own layer on a wavy path. Particle emitters proved unreliable for this on recent macOS.
@MainActor
final class LeavesLayer: CALayer {
    private var images: [(image: CGImage, petal: Bool)] = []
    private var palette: LeafPalette?
    private var drift: Double = 0
    /// Leaves per second.
    private var rate: Double = 0
    private var timer: Timer?
    private var rng = SystemRandomNumberGenerator()

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ scene: WeatherScene, amount: Double) {
        guard scene.leaves, amount > 0 else {
            stop()
            return
        }
        if palette != scene.palette {
            palette = scene.palette
            let spring = scene.palette == .spring
            images = Sprites.colors(for: scene.palette).enumerated().map { i, color in
                let petal = spring && i < 3
                return (Sprites.leaf(color: color, petal: petal, size: petal ? 14 : 18), petal)
            }
        }
        drift = scene.drift
        rate = 1.4 * amount * Double(bounds.height / 900)
        if timer == nil {
            let t = Timer(timeInterval: 0.25, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    /// No new leaves. The ones in the air finish their trip.
    func stop() {
        rate = 0
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerFired() {
        var chance = rate * 0.25
        while chance > 0 {
            if Double.random(in: 0..<1, using: &rng) < chance { spawn() }
            chance -= 1
        }
    }

    private func spawn() {
        guard let pick = images.randomElement(using: &rng) else { return }
        let size = bounds.size
        let rightward = drift >= 0
        let speed = max(abs(drift) * 1.6, 160) * Double.random(in: 0.75...1.3, using: &rng)
        let startX: CGFloat = rightward ? -30 : size.width + 30
        let endX: CGFloat = rightward ? size.width + 30 : -30
        var y = size.height * CGFloat.random(in: 0.3...0.95, using: &rng)
        let fall = CGFloat.random(in: 60...240, using: &rng)
        let waves = CGFloat.random(in: 2...4, using: &rng)
        let amplitude = CGFloat.random(in: 18...60, using: &rng)
        let phase = CGFloat.random(in: 0...(2 * .pi), using: &rng)
        let path = CGMutablePath()
        let steps = 24
        for i in 0...steps {
            let u = CGFloat(i) / CGFloat(steps)
            let x = startX + (endX - startX) * u
            y -= fall / CGFloat(steps)
            let p = CGPoint(x: x, y: y + amplitude * sin(u * waves * 2 * .pi + phase))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        let duration = Double(abs(endX - startX)) / speed

        let leaf = CALayer()
        leaf.contents = pick.image
        leaf.contentsScale = Sprites.scale
        leaf.bounds = CGRect(x: 0, y: 0, width: CGFloat(pick.image.width) / Sprites.scale,
                             height: CGFloat(pick.image.height) / Sprites.scale)
        let scale = CGFloat.random(in: 0.7...1.3, using: &rng)
        leaf.transform = CATransform3DMakeScale(scale, scale, 1)
        leaf.position = CGPoint(x: endX, y: y)

        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .cubicPaced
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = (rightward ? -1 : 1) * Double.random(in: 2...7, using: &rng)
        // Squashing one axis back and forth looks like the leaf turning over in the air.
        let flip = CABasicAnimation(keyPath: "transform.scale.y")
        flip.fromValue = scale
        flip.toValue = scale * 0.2
        flip.duration = Double.random(in: 0.25...0.6, using: &rng)
        flip.autoreverses = true
        flip.repeatCount = .infinity
        let group = CAAnimationGroup()
        group.animations = [move, spin, flip]
        group.duration = duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak leaf] in leaf?.removeFromSuperlayer() }
        leaf.add(group, forKey: "fly")
        addSublayer(leaf)
        CATransaction.commit()
    }
}
