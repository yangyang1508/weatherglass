import AppKit
import QuartzCore
import WeatherglassCore

/// Water beads on the screen glass. Some sit and dry up; big ones slide down and leave a trail.
/// Shake the pointer fast across them to wipe them away.
@MainActor
final class GlassLayer: CALayer {
    private struct Bead {
        let layer: CALayer
        let center: CGPoint
        let radius: CGFloat
        /// Only resting beads can be wiped; sliding ones are mid-animation.
        var resting: Bool
    }

    private var beads: [ObjectIdentifier: Bead] = [:]
    private var timer: Timer?
    private var budget: Double = 0
    private var rate: Double = 0
    private var maxBeads = 0
    private var drizzle = false
    private var frozen = false

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var count: Int { beads.count }

    /// - Parameter prewarm: start with the glass already wet, instead of dry.
    func apply(_ scene: WeatherScene, amount: Double, prewarm: Bool = false) {
        let wet = scene.precipitation == .rain || scene.precipitation == .drizzle
        drizzle = scene.precipitation == .drizzle
        frozen = scene.freezing
        let width = Double(bounds.width / 1440)
        if wet && amount > 0 {
            rate = (drizzle ? 6 + 12 * amount : 3.5 + 12 * amount) * width
            maxBeads = Int((70 + 200 * amount) * width)
            if prewarm {
                for _ in beads.count..<max(beads.count, maxBeads / 2) { spawn(settled: true) }
            }
            start()
        } else {
            rate = 0
            stop()
        }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.2, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stops new beads. The ones on the glass dry up on their own.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() {
        stop()
        for b in beads.values { b.layer.removeFromSuperlayer() }
        beads.removeAll()
    }

    @objc private func timerFired() {
        tick(0.2)
    }

    private func tick(_ dt: Double) {
        budget += rate * dt
        while budget >= 1 {
            budget -= 1
            if beads.count < maxBeads { spawn() }
        }
    }

    /// - Parameter settled: the bead was already there; it does not land, and it waits longer to slide.
    private func spawn(settled: Bool = false) {
        let size = bounds.size
        guard size.width > 20, size.height > 20 else { return }
        let big = !drizzle && Double.random(in: 0...1) < 0.35
        let d: CGFloat = drizzle ? [2.5, 3, 4].randomElement()! : (big ? [9, 12, 15].randomElement()! : [3, 4, 5, 6].randomElement()!)
        let stretch: CGFloat = [1, 1.08, 1.15].randomElement()!
        let image = Sprites.droplet(d, stretch: stretch)
        let p = CGPoint(x: CGFloat.random(in: 4...(size.width - 4)), y: CGFloat.random(in: size.height * 0.08...(size.height - 4)))

        let l = CALayer()
        l.contents = image
        l.contentsScale = Sprites.scale
        l.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / Sprites.scale, height: CGFloat(image.height) / Sprites.scale)
        l.position = p
        l.opacity = frozen ? 0.95 : 0.9
        l.actions = ["position": NSNull(), "opacity": NSNull(), "transform": NSNull()]
        addSublayer(l)
        let id = ObjectIdentifier(l)
        beads[id] = Bead(layer: l, center: p, radius: d / 2, resting: true)

        if !settled {
            // Lands with a tiny splat.
            let land = CABasicAnimation(keyPath: "transform.scale")
            land.fromValue = 0.4
            land.toValue = 1
            land.duration = 0.14
            land.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.add(land, forKey: "land")
        }

        if big && !frozen && Double.random(in: 0...1) < 0.65 {
            let wait = settled ? Double.random(in: 1...24) : Double.random(in: 0.6...5)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.slide(id)
            }
        } else {
            let life = frozen ? Double.random(in: 25...45) : Double.random(in: 6...26)
            DispatchQueue.main.asyncAfter(deadline: .now() + life) { [weak self] in
                self?.dry(id)
            }
        }
    }

    /// A heavy bead runs down the glass in fits and starts, leaving a few small beads behind.
    private func slide(_ id: ObjectIdentifier) {
        guard var b = beads[id] else { return }
        b.resting = false
        beads[id] = b
        let distance = CGFloat.random(in: 140...min(620, max(b.center.y - 10, 150)))
        let duration = Double(distance / CGFloat.random(in: 110...220))
        var points: [CGPoint] = []
        let steps = 7
        var x = b.center.x
        for i in 0...steps {
            let y = b.center.y - distance * CGFloat(i) / CGFloat(steps)
            if i > 0 { x += CGFloat.random(in: -3...3) }
            points.append(CGPoint(x: x, y: y))
        }
        let path = CGMutablePath()
        path.addLines(between: points)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .cubicPaced
        // Stalls for a moment part of the way down, like a real drop.
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.05, 0.6, 0.95)
        move.duration = duration
        let stretch = CABasicAnimation(keyPath: "transform.scale.y")
        stretch.fromValue = 1
        stretch.toValue = 1.35
        stretch.duration = 0.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = b.layer.opacity
        fade.toValue = 0
        fade.beginTime = duration * 0.8
        fade.duration = duration * 0.2
        let group = CAAnimationGroup()
        group.animations = [move, stretch, fade]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.remove(id) }
        }
        b.layer.add(group, forKey: "slide")
        CATransaction.commit()

        // The trail: a few tiny beads that stay behind and dry.
        for i in 1...Int.random(in: 2...5) {
            let t = CGFloat(i) / 6
            let at = CGPoint(x: b.center.x + CGFloat.random(in: -2...2), y: b.center.y - distance * t * 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(t)) { [weak self] in
                self?.trail(at)
            }
        }
    }

    private func trail(_ p: CGPoint) {
        guard superlayer != nil else { return }
        let image = Sprites.droplet([2, 2.5, 3].randomElement()!)
        let l = CALayer()
        l.contents = image
        l.contentsScale = Sprites.scale
        l.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / Sprites.scale, height: CGFloat(image.height) / Sprites.scale)
        l.position = p
        l.opacity = 0.8
        l.actions = ["position": NSNull(), "opacity": NSNull()]
        addSublayer(l)
        let id = ObjectIdentifier(l)
        beads[id] = Bead(layer: l, center: p, radius: 1.5, resting: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 3...9)) { [weak self] in
            self?.dry(id)
        }
    }

    private func dry(_ id: ObjectIdentifier) {
        guard let b = beads[id], b.resting else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = b.layer.opacity
        fade.toValue = 0
        fade.duration = 1.6
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.7
        shrink.duration = 1.6
        b.layer.opacity = 0
        b.layer.transform = CATransform3DMakeScale(0.7, 0.7, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.remove(id) }
        }
        b.layer.add(fade, forKey: "dry")
        b.layer.add(shrink, forKey: "shrink")
        CATransaction.commit()
        var resting = b
        resting.resting = false
        beads[id] = resting
    }

    private func remove(_ id: ObjectIdentifier) {
        beads.removeValue(forKey: id)?.layer.removeFromSuperlayer()
    }

    /// Wipes resting beads near the line from `a` to `b` (in this layer's coordinates), pushing them along.
    func wipe(from a: CGPoint, to b: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = max(dx * dx + dy * dy, 1)
        let reach: CGFloat = 56
        for (id, bead) in beads where bead.resting {
            let t = max(0, min(1, ((bead.center.x - a.x) * dx + (bead.center.y - a.y) * dy) / len2))
            let px = a.x + t * dx, py = a.y + t * dy
            let dist = hypot(bead.center.x - px, bead.center.y - py)
            guard dist < reach + bead.radius else { continue }
            var gone = bead
            gone.resting = false
            beads[id] = gone
            let len = sqrt(len2)
            let push = CGPoint(x: bead.center.x + dx / len * 40, y: bead.center.y + dy / len * 40)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: bead.center)
            move.toValue = NSValue(point: push)
            let smear = CABasicAnimation(keyPath: "transform.scale.x")
            smear.fromValue = 1
            smear.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = bead.layer.opacity
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [move, smear, fade]
            g.duration = 0.25
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated { self?.remove(id) }
            }
            bead.layer.add(g, forKey: "wipe")
            CATransaction.commit()
        }
    }
}
