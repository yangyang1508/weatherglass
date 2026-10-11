import AppKit
import QuartzCore
import WeatherglassCore

/// Draws the snow lying on window tops, and the clumps that fall when a window moves.
@MainActor
final class SnowCapsLayer: CALayer {
    /// One cap: a soft shadow under it, and a white-to-blue body.
    private final class CapLayers {
        let shadow = CAShapeLayer()
        let body = CAGradientLayer()
        let mask = CAShapeLayer()

        init(in parent: CALayer) {
            shadow.fillColor = CGColor(gray: 1, alpha: 1)
            shadow.shadowColor = CGColor(gray: 0.1, alpha: 1)
            shadow.shadowOpacity = 0.32
            shadow.shadowRadius = 1.6
            // A thin outline that keeps white snow visible on a white window. It points up, because a
            // shadow below the snow would look like a gap between the snow and the window.
            shadow.shadowOffset = CGSize(width: 0, height: 0.8)
            body.colors = [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1),
                CGColor(red: 0.82, green: 0.88, blue: 0.96, alpha: 1),
            ]
            body.locations = [0, 0.55, 1]
            body.startPoint = CGPoint(x: 0.5, y: 1)
            body.endPoint = CGPoint(x: 0.5, y: 0)
            body.mask = mask
            for l in [shadow, body, mask] as [CALayer] {
                l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "shadowPath": NSNull()]
            }
            parent.addSublayer(shadow)
            parent.addSublayer(body)
        }

        func remove() {
            shadow.removeFromSuperlayer()
            body.removeFromSuperlayer()
        }
    }

    private var caps: [UInt32: CapLayers] = [:]
    /// Where this overlay's screen sits, in Cocoa global coordinates.
    var screenFrame: CGRect = .zero

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var isEmpty: Bool { caps.isEmpty }

    func render(_ list: [SnowField.Cap]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var keep = Set<UInt32>()
        for cap in list {
            guard let path = Self.path(for: cap, origin: screenFrame.origin), !path.isEmpty else { continue }
            let box = path.boundingBoxOfPath
            guard box.intersects(bounds) else { continue }
            keep.insert(cap.windowID)
            let l = caps[cap.windowID] ?? CapLayers(in: self)
            caps[cap.windowID] = l
            l.shadow.path = path
            l.shadow.shadowPath = path
            l.body.frame = box
            // The mask lives in the body's coordinates.
            var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            l.mask.path = path.copy(using: &shift)
            l.mask.frame = CGRect(origin: .zero, size: box.size)
        }
        for (id, l) in caps where !keep.contains(id) {
            l.remove()
            caps[id] = nil
        }
    }

    func clear() {
        for l in caps.values { l.remove() }
        caps.removeAll()
    }

    /// The corner radius of a standard window: about 12 pt on macOS 26 (measured), 10 pt before.
    static let cornerRadius: CGFloat =
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 12 : 10

    /// A smooth outline over the snow in each uncovered part of the edge, in this layer's coordinates.
    ///
    /// Window corners are round. On a corner the snow lies on the curve, and it thins to nothing where
    /// the curve gets too steep for snow to stay. So there is no gap under the ends of a cap.
    static func path(for cap: SnowField.Cap, origin: CGPoint) -> CGPath? {
        let bin = CGFloat(SnowCap.bin)
        let r = cornerRadius
        let baseY = cap.frame.maxY - origin.y
        let left = cap.frame.minX - origin.x
        let right = left + cap.frame.width
        // Snow slides off where the corner is steeper than about 50°.
        let start = r * 0.25
        // The cap sits a little into the window, so no light shows between them.
        let sink: CGFloat = 1.5

        /// The top of the window at `x`, following the round corners.
        func surface(_ x: CGFloat) -> CGFloat {
            let u = r - min(max(min(x - left, right - x), 0), r)
            return baseY - (r - sqrt(max(r * r - u * u, 0)))
        }
        /// 0 at the end of the snow on a corner, 1 a little way in.
        func thinning(_ x: CGFloat) -> CGFloat {
            let t = min(max((min(x - left, right - x) - start) / r, 0), 1)
            return t * t * (3 - 2 * t)
        }

        let p = CGMutablePath()
        for span in cap.visible {
            let a = max(Int(((span.lowerBound - cap.frame.minX) / bin).rounded(.down)), 0)
            let b = min(Int(((span.upperBound - cap.frame.minX) / bin).rounded(.up)), cap.heights.count) - 1
            guard b > a else { continue }
            let x0 = max(span.lowerBound - origin.x, left + start)
            let x1 = min(span.upperBound - origin.x, right - start)
            guard x1 > x0 else { continue }
            // An end on a corner comes down to the window. An end cut by a covering window stops straight,
            // so the cap meets that window cleanly.
            let onLeftCorner = x0 <= left + start + 0.01
            let onRightCorner = x1 >= right - start - 0.01
            var pts: [CGPoint] = []
            for i in a...b {
                let x = left + (CGFloat(i) + 0.5) * bin
                guard x > x0, x < x1 else { continue }
                pts.append(CGPoint(x: x, y: surface(x) + CGFloat(cap.heights[i]) * thinning(x)))
            }
            guard let first = pts.first, let last = pts.last,
                  pts.contains(where: { $0.y - surface($0.x) > 0.6 }) else { continue }
            let all = [CGPoint(x: x0, y: onLeftCorner ? surface(x0) : first.y)] + pts
                + [CGPoint(x: x1, y: onRightCorner ? surface(x1) : last.y)]
            p.move(to: CGPoint(x: x0, y: surface(x0) - sink))
            p.addLine(to: all[0])
            // Catmull-Rom through the column tops, as cubic Béziers.
            for i in 0..<(all.count - 1) {
                let p0 = all[max(i - 1, 0)], p1 = all[i], p2 = all[i + 1], p3 = all[min(i + 2, all.count - 1)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                p.addCurve(to: p2, control1: c1, control2: c2)
            }
            // Back along the underside. It is flat except on the corners, so only those need points.
            var x = x1
            while x > x0 {
                p.addLine(to: CGPoint(x: x, y: surface(x) - sink))
                let inCorner = x > right - r || x < left + r + 1
                x = inCorner ? x - 1 : max(left + r, x0)
            }
            p.addLine(to: CGPoint(x: x0, y: surface(x0) - sink))
            p.closeSubpath()
        }
        return p
    }

    /// Snow that slid off a window: clumps tumble to the bottom of the screen and a puff of powder hangs in the air.
    func drop(_ fall: SnowField.Fall) {
        let bin = CGFloat(SnowCap.bin)
        let baseY = fall.frame.maxY - screenFrame.minY
        let left = fall.frame.minX - screenFrame.minX
        guard left + fall.frame.width > 0, left < bounds.width, baseY > 0, baseY < bounds.height + 40 else { return }
        var i = 0
        var seed = Int(fall.windowID)
        while i < fall.heights.count {
            let h = CGFloat(fall.heights[i])
            let step = max(Int(CGFloat.random(in: 8...16) / bin), 1)
            defer { i += step }
            guard h > 1.2 else { continue }
            seed += 1
            let x = left + (CGFloat(i) + 0.5) * bin
            guard x > -20, x < bounds.width + 20 else { continue }
            let d = max(h * CGFloat.random(in: 0.8...1.35), 4)
            clump(at: CGPoint(x: x, y: baseY + h / 2), size: d, seed: seed % 9)
        }
        puff(from: CGPoint(x: left, y: baseY), width: fall.frame.width,
             amount: fall.heights.reduce(0, +) / Double(max(fall.heights.count, 1)))
    }

    private func clump(at p: CGPoint, size d: CGFloat, seed: Int) {
        let image = Sprites.clump(d.rounded(), seed: seed)
        let l = CALayer()
        l.contents = image
        l.contentsScale = Sprites.scale
        l.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / Sprites.scale, height: CGFloat(image.height) / Sprites.scale)
        l.position = p
        addSublayer(l)

        let gravity: CGFloat = 1900
        let floorY: CGFloat = -d
        let distance = max(p.y - floorY, 10)
        let delay = Double.random(in: 0...0.12)
        let fallTime = Double(sqrt(2 * distance / gravity))
        let driftX = CGFloat.random(in: -18...18)

        let move = CAKeyframeAnimation(keyPath: "position")
        let path = CGMutablePath()
        path.move(to: p)
        path.addQuadCurve(to: CGPoint(x: p.x + driftX, y: floorY), control: CGPoint(x: p.x + driftX * 0.2, y: p.y))
        move.path = path
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.9, 0.6)
        move.duration = fallTime
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.toValue = CGFloat.random(in: -2.5...2.5)
        spin.duration = fallTime
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 0.8
        shrink.duration = fallTime
        let g = CAAnimationGroup()
        g.animations = [move, spin, shrink]
        g.duration = fallTime
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "fall")
        CATransaction.commit()
    }

    private func puff(from p: CGPoint, width: CGFloat, amount: Double) {
        let e = CAEmitterLayer()
        e.frame = bounds
        e.contentsScale = contentsScale
        e.emitterShape = .line
        e.emitterPosition = CGPoint(x: p.x + width / 2, y: p.y + 3)
        e.emitterSize = CGSize(width: width, height: 1)
        let c = CAEmitterCell()
        c.contents = Sprites.flake(3, blur: 0.3)
        c.contentsScale = Sprites.scale
        c.birthRate = Float(min(max(amount, 1), 14)) * Float(width / 6)
        c.lifetime = 2.2
        c.lifetimeRange = 0.8
        c.velocity = 70
        c.velocityRange = 50
        c.emissionLongitude = .pi / 2
        c.emissionRange = .pi / 2.2
        c.yAcceleration = -140
        c.scaleRange = 0.5
        c.alphaSpeed = -0.45
        e.emitterCells = [c]
        addSublayer(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { e.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { e.removeFromSuperlayer() }
    }
}
