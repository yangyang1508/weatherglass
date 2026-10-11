import AppKit
import QuartzCore
import WeatherglassCore

/// Rain, drizzle, snow or hail, falling in two to four layers of depth.
///
/// Rain, drizzle, hail and small snowflakes are tiles that scroll down the screen. Big snowflakes close to
/// the "lens" are layers of their own. Particle emitters were tried first, but on recent macOS they do not
/// draw fast particles, and slow ones never got past the top third of the screen. Core Animation runs all of
/// this in the window server, so it costs the app almost no CPU.
@MainActor
final class PrecipitationLayer: CALayer {
    /// One depth of rain, drizzle, hail or small snow.
    private struct Sheet {
        /// Streaks or flakes per 100 × 100 pt at full intensity.
        var density: Double
        var length: CGFloat = 0
        var width: CGFloat = 1
        /// Hailstone diameter. Zero means streaks.
        var hail: CGFloat = 0
        /// A snowflake image. Set for snow.
        var flake: CGImage?
        var speed: CGFloat
        var alpha: Float
        /// Snow sways from side to side by this many points.
        var sway: CGFloat = 0
        var swayPeriod: CFTimeInterval = 0
    }

    private var layers: [CALayer] = []
    private(set) var kind: Precipitation = .none
    private var drift: Double = 0
    private var isNight = false
    private var level: Double = 0
    private var builtSize: CGSize = .zero

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `scene`. A change of kind, wind or intensity replaces the layers; the old ones fade out.
    /// - Parameters:
    ///   - amount: user intensity times weather intensity, 0...~1.6.
    ///   - prewarm: show the weather at full strength at once, instead of fading it in.
    func apply(_ scene: WeatherScene, amount: Double, prewarm: Bool) {
        let level = Self.level(for: amount)
        let rebuild = scene.precipitation != kind || abs(scene.drift - drift) > 4 || scene.isNight != isNight
            || layers.isEmpty || prewarm || level != self.level
        kind = scene.precipitation
        drift = scene.drift
        isNight = scene.isNight
        self.level = level
        if rebuild {
            retire()
            guard kind != .none, level > 0 else { return }
            build(prewarm: prewarm)
        }
    }

    /// Tiles are drawn for a few fixed intensities, so a small change does not redraw them.
    static func level(for amount: Double) -> Double {
        guard amount > 0.02 else { return 0 }
        return max(0.25, (min(amount, 1.6) * 4).rounded() / 4)
    }

    /// Stops the weather. Everything fades out.
    func retire() {
        let old = layers
        layers = []
        guard !old.isEmpty else { return }
        for l in old {
            (l as? FlakeShower)?.stop()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = l.presentation()?.opacity ?? l.opacity
            fade.toValue = 0
            fade.duration = 1.2
            l.opacity = 0
            l.add(fade, forKey: "fade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            for l in old { l.removeFromSuperlayer() }
        }
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        // A new screen size needs new tile grids.
        if !layers.isEmpty, builtSize != bounds.size, kind != .none {
            retire()
            build(prewarm: true)
        }
    }

    private func build(prewarm: Bool) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        builtSize = size
        let night: Float = isNight ? 0.85 : 1
        switch kind {
        case .none:
            break
        case .snow:
            // Two sheets per depth, at different speeds, so the flakes do not all move together.
            let small = Sprites.flake(3, blur: 0.4)
            let medium = Sprites.flake(5, blur: 0.25)
            for (i, s) in [Sheet(density: 6.2, flake: small, speed: 36, alpha: 0.6, sway: 14, swayPeriod: 9),
                           Sheet(density: 6.2, flake: small, speed: 48, alpha: 0.6, sway: 11, swayPeriod: 11),
                           Sheet(density: 1.6, flake: medium, speed: 60, alpha: 0.85, sway: 22, swayPeriod: 7),
                           Sheet(density: 1.6, flake: medium, speed: 80, alpha: 0.85, sway: 18, swayPeriod: 8.5)].enumerated() {
                addSheet(s, alphaScale: night, seed: UInt64(30 + i), size: size, fadeIn: !prewarm)
            }
            let near = FlakeShower()
            near.frame = CGRect(origin: .zero, size: size)
            near.start([.init(image: Sprites.flake(9, blur: 0.35), birth: 7, speed: 90...140, alpha: 0.9 * night,
                              sway: 32, swayPeriod: 5),
                        .init(image: Sprites.flake(24, blur: 1), birth: 0.7, speed: 140...200, alpha: 0.35 * night,
                              sway: 40, swayPeriod: 4)],
                       level: level, drift: CGFloat(drift))
            if !prewarm { fadeIn(near, to: 1) }
            addSublayer(near)
            layers.append(near)
        case .rain:
            for (i, s) in [Sheet(density: 2.2, length: 14, width: 1, speed: 1100, alpha: 0.55),
                           Sheet(density: 0.7, length: 26, width: 1.4, speed: 1500, alpha: 0.65),
                           Sheet(density: 0.1, length: 44, width: 2.2, speed: 2000, alpha: 0.6)].enumerated() {
                addSheet(s, alphaScale: night, seed: UInt64(i), size: size, fadeIn: !prewarm)
            }
        case .drizzle:
            for (i, s) in [Sheet(density: 2, length: 7, width: 1, speed: 480, alpha: 0.5),
                           Sheet(density: 0.5, length: 11, width: 1.2, speed: 650, alpha: 0.55)].enumerated() {
                addSheet(s, alphaScale: night, seed: UInt64(10 + i), size: size, fadeIn: !prewarm)
            }
        case .hail:
            for (i, s) in [Sheet(density: 0.8, length: 20, width: 1.2, speed: 1400, alpha: 0.5),
                           Sheet(density: 0.55, hail: 4, speed: 1100, alpha: 0.95),
                           Sheet(density: 0.12, hail: 7, speed: 1500, alpha: 0.95)].enumerated() {
                addSheet(s, alphaScale: i == 0 ? night : 1, seed: UInt64(20 + i), size: size, fadeIn: !prewarm)
            }
        }
    }

    private func fadeIn(_ l: CALayer, to opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = opacity
        fade.duration = 1.5
        l.add(fade, forKey: "fade")
    }

    /// A grid of identical tiles, turned to match the wind, that slides down by one tile and repeats.
    private func addSheet(_ s: Sheet, alphaScale: Float, seed: UInt64, size: CGSize, fadeIn: Bool) {
        let diagonal = hypot(size.width, size.height)
        let side = max(300, (diagonal / 7).rounded(.up))
        let count = Int((s.density * level * Double(side * side) / 10_000).rounded())
        guard count > 0 else { return }
        let images = (0..<2).map {
            let seed = seed &* 31 &+ UInt64($0) &+ UInt64(level * 8) &* 1009
            if let flake = s.flake { return Sprites.snowTile(side: side, count: count, flake: flake, seed: seed) }
            return Sprites.precipitationTile(side: side, count: count, length: s.length, width: s.width, alpha: 1,
                                             hail: s.hail, seed: seed)
        }
        let columns = Int((diagonal / side).rounded(.up)) + 1
        let rows = columns + 1

        let holder = CALayer()
        holder.bounds = CGRect(x: 0, y: 0, width: CGFloat(columns) * side, height: CGFloat(rows) * side)
        holder.position = CGPoint(x: size.width / 2, y: size.height / 2)
        holder.transform = CATransform3DMakeRotation(atan(CGFloat(drift) / s.speed), 0, 0, 1)
        holder.opacity = s.alpha * alphaScale

        let grid = CALayer()
        grid.frame = holder.bounds
        var rng = SplitMix64(seed: seed &+ 77)
        for c in 0..<columns {
            // Each column starts at a different height, so the tiles do not line up in rows.
            let offset = CGFloat.random(in: 0..<side, using: &rng)
            let image = images[Int.random(in: 0..<images.count, using: &rng)]
            for r in 0...(rows + 1) {
                let t = CALayer()
                t.contents = image
                t.contentsScale = Sprites.scale
                t.frame = CGRect(x: CGFloat(c) * side, y: CGFloat(r) * side - offset, width: side, height: side)
                grid.addSublayer(t)
            }
        }
        holder.addSublayer(grid)

        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = grid.position.y
        fall.toValue = grid.position.y - side
        fall.duration = Double(side / hypot(s.speed, CGFloat(drift)))
        fall.repeatCount = .infinity
        fall.timeOffset = Double.random(in: 0..<fall.duration)
        grid.add(fall, forKey: "fall")

        if s.sway > 0 {
            let sway = CAKeyframeAnimation(keyPath: "transform.translation.x")
            sway.values = [0, s.sway, 0, -s.sway, 0]
            sway.duration = s.swayPeriod
            sway.calculationMode = .cubic
            sway.repeatCount = .infinity
            sway.timeOffset = Double.random(in: 0..<s.swayPeriod)
            grid.add(sway, forKey: "sway")
        }

        if fadeIn { self.fadeIn(holder, to: holder.opacity) }
        addSublayer(holder)
        layers.append(holder)
    }
}

/// Big snowflakes close to the "lens". Each flake is its own layer, so each one falls at its own speed.
@MainActor
private final class FlakeShower: CALayer {
    struct Depth {
        var image: CGImage
        /// Flakes per second on a 1440 pt wide screen at full intensity.
        var birth: Double
        /// Downward speed, in points per second.
        var speed: ClosedRange<CGFloat>
        var alpha: Float
        /// Flakes sway from side to side by about this many points.
        var sway: CGFloat
        var swayPeriod: CFTimeInterval
    }

    private var depths: [Depth] = []
    /// Flakes per second, for each depth.
    private var rates: [Double] = []
    private var drift: CGFloat = 0
    private var timer: Timer?
    private var rng = SystemRandomNumberGenerator()
    /// Flakes start and end this far outside the screen, so they never pop in or out.
    private let margin: CGFloat = 70

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Starts with the screen already full of flakes at random heights.
    func start(_ depths: [Depth], level: Double, drift: CGFloat) {
        self.depths = depths
        self.drift = drift
        let size = bounds.size
        rates = depths.map { d in
            let time = Double((size.height + margin * 2) / ((d.speed.lowerBound + d.speed.upperBound) / 2))
            // Wind blows flakes in from the side, so more of them start off the screen.
            let width = size.width + abs(drift) * CGFloat(time)
            return d.birth * level * Double(width / 1440)
        }
        for (i, d) in depths.enumerated() {
            let time = Double((size.height + margin * 2) / d.speed.lowerBound)
            for _ in 0..<Int((rates[i] * time).rounded()) {
                spawn(d, age: Double.random(in: 0..<time, using: &rng))
            }
        }
        let t = Timer(timeInterval: 0.25, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// No new flakes.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerFired() {
        for (i, d) in depths.enumerated() {
            var chance = rates[i] * 0.25
            while chance > 0 {
                if Double.random(in: 0..<1, using: &rng) < chance {
                    // A small random age spreads the flakes of one tick over its quarter second.
                    spawn(d, age: Double.random(in: 0..<0.25, using: &rng))
                }
                chance -= 1
            }
        }
    }

    /// - Parameter age: seconds the flake has already been falling.
    private func spawn(_ d: Depth, age: Double) {
        let size = bounds.size
        let speed = CGFloat.random(in: d.speed, using: &rng)
        let duration = Double((size.height + margin * 2) / speed)
        guard age < duration else { return }
        let travel = drift * CGFloat(duration)
        let x = CGFloat.random(in: (min(0, -travel) - margin)...(max(size.width, size.width - travel) + margin), using: &rng)
        let end = CGPoint(x: x + travel, y: -margin)

        let flake = CALayer()
        flake.contents = d.image
        flake.contentsScale = Sprites.scale
        let k = CGFloat.random(in: 0.75...1.25, using: &rng)
        flake.bounds = CGRect(x: 0, y: 0, width: CGFloat(d.image.width) / Sprites.scale * k,
                              height: CGFloat(d.image.height) / Sprites.scale * k)
        flake.opacity = d.alpha * Float.random(in: 0.8...1, using: &rng)
        flake.position = end

        let fall = CABasicAnimation(keyPath: "position")
        fall.fromValue = NSValue(point: CGPoint(x: x, y: size.height + margin))
        fall.toValue = NSValue(point: end)
        let sway = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let reach = d.sway * CGFloat.random(in: 0.6...1.2, using: &rng)
        sway.values = [0, reach, 0, -reach, 0]
        sway.duration = d.swayPeriod * Double.random(in: 0.8...1.25, using: &rng)
        sway.calculationMode = .cubic
        sway.repeatCount = .infinity
        sway.timeOffset = Double.random(in: 0..<sway.duration, using: &rng)
        let group = CAAnimationGroup()
        group.animations = [fall, sway]
        group.duration = duration
        // A start time in the past puts the flake part of the way down already.
        group.beginTime = convertTime(CACurrentMediaTime(), from: nil) - age
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak flake] in flake?.removeFromSuperlayer() }
        flake.add(group, forKey: "fall")
        addSublayer(flake)
        CATransaction.commit()
    }
}
