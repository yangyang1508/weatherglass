import AppKit
import WeatherglassCore

/// Every particle image, drawn in code at 2× scale. No image files ship with the app.
///
/// Each sprite has a faint dark edge as well as a light core, so it shows on white windows and on dark ones.
@MainActor
enum Sprites {
    static let scale: CGFloat = 2
    private static var cache: [String: CGImage] = [:]

    private static func draw(_ key: String, size: CGSize, _ body: (CGContext, CGSize) -> Void) -> CGImage {
        if let hit = cache[key] { return hit }
        let image = render(size: size, body)
        cache[key] = image
        return image
    }

    private static func render(size: CGSize, _ body: (CGContext, CGSize) -> Void) -> CGImage {
        let w = max(Int((size.width * scale).rounded(.up)), 1)
        let h = max(Int((size.height * scale).rounded(.up)), 1)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        body(ctx, size)
        return ctx.makeImage()!
    }

    // MARK: Rain

    /// A square of falling streaks, or of hailstones, that repeats without a seam in both directions.
    /// The rain layer scrolls these down the screen. The head of each streak is at the bottom.
    static func precipitationTile(side: CGFloat, count: Int, length: CGFloat, width: CGFloat, alpha: CGFloat,
                                  hail: CGFloat, seed: UInt64) -> CGImage {
        render(size: CGSize(width: side, height: side)) { ctx, _ in
            var rng = SplitMix64(seed: seed)
            for _ in 0..<count {
                let p = CGPoint(x: CGFloat.random(in: 0..<side, using: &rng), y: CGFloat.random(in: 0..<side, using: &rng))
                let k = CGFloat.random(in: 0.75...1.25, using: &rng)
                // Draw near the edges a second time on the far side, so the tile wraps.
                for dx in [-side, 0, side] {
                    for dy in [-side, 0, side] {
                        let q = CGPoint(x: p.x + dx, y: p.y + dy)
                        guard q.x > -length, q.x < side + length, q.y > -length, q.y < side + length else { continue }
                        if hail > 0 {
                            let d = (hail + 3) * k
                            ctx.draw(hailstone(hail), in: CGRect(x: q.x - d / 2, y: q.y - d / 2, width: d, height: d))
                        } else {
                            streak(in: ctx, at: q, length: length * k, width: width, alpha: alpha)
                        }
                    }
                }
            }
        }
    }

    /// A square of snowflakes that repeats without a seam in both directions. Small snow scrolls these down the screen.
    static func snowTile(side: CGFloat, count: Int, flake: CGImage, seed: UInt64) -> CGImage {
        let w = CGFloat(flake.width) / scale
        let h = CGFloat(flake.height) / scale
        let tile = CGRect(x: 0, y: 0, width: side, height: side)
        return render(size: tile.size) { ctx, _ in
            var rng = SplitMix64(seed: seed)
            for _ in 0..<count {
                let p = CGPoint(x: CGFloat.random(in: 0..<side, using: &rng), y: CGFloat.random(in: 0..<side, using: &rng))
                let k = CGFloat.random(in: 0.7...1.3, using: &rng)
                ctx.setAlpha(CGFloat.random(in: 0.75...1, using: &rng))
                // Draw near the edges a second time on the far side, so the tile wraps.
                for dx in [-side, 0, side] {
                    for dy in [-side, 0, side] {
                        let r = CGRect(x: p.x + dx - w * k / 2, y: p.y + dy - h * k / 2, width: w * k, height: h * k)
                        if r.intersects(tile) { ctx.draw(flake, in: r) }
                    }
                }
            }
        }
    }

    private static func streak(in ctx: CGContext, at p: CGPoint, length: CGFloat, width: CGFloat, alpha: CGFloat) {
        let top = CGPoint(x: p.x, y: p.y + length / 2)
        let bottom = CGPoint(x: p.x, y: p.y - length / 2)
        ctx.setLineCap(.round)
        // Dark edge, wider, for light backgrounds.
        ctx.setLineWidth(width + 1)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: alpha * 0.32))
        ctx.move(to: top); ctx.addLine(to: bottom); ctx.strokePath()
        // Light core, fading in from the tail.
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.move(to: top); ctx.addLine(to: bottom)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let g = CGGradient(colorsSpace: nil, colors: [
            CGColor(red: 0.86, green: 0.92, blue: 1, alpha: 0),
            CGColor(red: 0.9, green: 0.95, blue: 1, alpha: alpha),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: top, end: bottom, options: [])
        ctx.restoreGState()
    }

    /// A water bead sitting on the glass: clear body, dark rim at the bottom, bright glint at the top.
    static func droplet(_ d: CGFloat, stretch: CGFloat = 1) -> CGImage {
        let key = "droplet-\(d)-\(stretch)"
        let size = CGSize(width: d + 4, height: d * stretch + 4)
        return draw(key, size: size) { ctx, size in
            let body = CGRect(x: 2, y: 2, width: d, height: d * stretch)
            // A soft shadow under the bead.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.6), blur: 1.2, color: CGColor(gray: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.05))
            ctx.fillEllipse(in: body)
            ctx.restoreGState()
            // Body: nearly clear in the middle, darker toward the bottom rim.
            ctx.saveGState()
            ctx.addEllipse(in: body)
            ctx.clip()
            let g = CGGradient(colorsSpace: nil, colors: [
                CGColor(gray: 1, alpha: 0.22),
                CGColor(gray: 0.6, alpha: 0.08),
                CGColor(gray: 0, alpha: 0.32),
            ] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
            // Light gathers at the bottom edge of a real drop.
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.38))
            ctx.fillEllipse(in: CGRect(x: body.midX - d * 0.22, y: body.minY + d * 0.1 * stretch, width: d * 0.44, height: d * 0.16 * stretch))
            ctx.restoreGState()
            // Glint.
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
            ctx.fillEllipse(in: CGRect(x: body.minX + d * 0.24, y: body.maxY - d * 0.36 * stretch, width: d * 0.22, height: d * 0.16 * stretch))
            // Rim.
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.16))
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: body.insetBy(dx: 0.25, dy: 0.25))
        }
    }

    // MARK: Snow and ice

    /// A soft snowflake. `blur` near 1 makes the out-of-focus flakes close to the "lens".
    static func flake(_ d: CGFloat, blur: CGFloat = 0.3) -> CGImage {
        let key = "flake-\(d)-\(blur)"
        let size = CGSize(width: d * 2 + 4, height: d * 2 + 4)
        return draw(key, size: size) { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = d / 2
            // A soft grey shadow just below the flake keeps it visible on white windows.
            let halo = CGGradient(colorsSpace: nil, colors: [
                CGColor(gray: 0.3, alpha: 0.24 * (1 - blur * 0.7)),
                CGColor(gray: 0.3, alpha: 0),
            ] as CFArray, locations: [0, 1])!
            let below = CGPoint(x: c.x, y: c.y - r * 0.3)
            ctx.drawRadialGradient(halo, startCenter: below, startRadius: 0, endCenter: below, endRadius: r * 1.35 + 1, options: [])
            let solid = 0.55 * (1 - blur)
            let core = CGGradient(colorsSpace: nil, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                CGColor(red: 0.97, green: 0.98, blue: 1, alpha: 0.9),
                CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 0),
            ] as CFArray, locations: [0, solid, 1])!
            ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
    }

    /// A hailstone: small, icy, with a hard edge.
    static func hailstone(_ d: CGFloat) -> CGImage {
        draw("hail-\(d)", size: CGSize(width: d + 3, height: d + 3)) { ctx, size in
            let r = CGRect(x: 1.5, y: 1.5, width: d, height: d)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1, color: CGColor(gray: 0, alpha: 0.4))
            let g = CGGradient(colorsSpace: nil, colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.98),
                CGColor(red: 0.78, green: 0.87, blue: 0.95, alpha: 0.95),
            ] as CFArray, locations: [0, 1])!
            ctx.addEllipse(in: r)
            ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [])
        }
    }

    /// A lump of snow that falls off a window.
    static func clump(_ d: CGFloat, seed: Int) -> CGImage {
        draw("clump-\(d)-\(seed)", size: CGSize(width: d + 6, height: d + 6)) { ctx, size in
            var rng = SplitMix64(seed: UInt64(seed) &* 7919 &+ UInt64(d * 10))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: CGColor(gray: 0.2, alpha: 0.35))
            ctx.setFillColor(CGColor(red: 0.98, green: 0.99, blue: 1, alpha: 1))
            for _ in 0..<5 {
                let r = d / 2 * CGFloat.random(in: 0.45...0.75, using: &rng)
                let o = CGPoint(x: c.x + CGFloat.random(in: -d / 4...d / 4, using: &rng),
                                y: c.y + CGFloat.random(in: -d / 4...d / 4, using: &rng))
                ctx.fillEllipse(in: CGRect(x: o.x - r, y: o.y - r, width: r * 2, height: r * 2))
            }
        }
    }

    // MARK: Fog and wind

    /// A big soft cloud of fog, made of blurred random puffs.
    static func fogPuff(_ d: CGFloat, seed: Int) -> CGImage {
        draw("fog-\(d)-\(seed)", size: CGSize(width: d, height: d * 0.6)) { ctx, size in
            var rng = SplitMix64(seed: UInt64(seed) &+ 1)
            for _ in 0..<26 {
                let r = CGFloat.random(in: d * 0.08...d * 0.22, using: &rng)
                let x = CGFloat.random(in: r...(size.width - r), using: &rng)
                let y = CGFloat.random(in: r...(size.height - r), using: &rng)
                let g = CGGradient(colorsSpace: nil, colors: [
                    CGColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 0.16),
                    CGColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 0),
                ] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                       endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
            }
        }
    }

    /// Leaf (or, in spring, petal) colors for each season.
    static func colors(for palette: LeafPalette) -> [CGColor] {
        let hex: [UInt32]
        switch palette {
        case .autumn: hex = [0xD9622B, 0xE8A23A, 0xB5382A, 0xC9822F, 0x9C4A26]
        case .spring: hex = [0xF7C6D0, 0xF3A6B8, 0xFBE3E8, 0x9CCB6B]
        case .summer: hex = [0x4E8B3A, 0x6FA84B, 0x8DBF5A, 0x3E7A33]
        case .winter: hex = [0x8B6B4A, 0xA68A64, 0x6E5640, 0xB39B78]
        case .tropical: hex = [0x3F8F3A, 0x5FAF46, 0x9CC43E, 0xD9B53B]
        }
        return hex.map { CGColor(red: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255,
                                 blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
    }

    /// A leaf with a vein and a stem, or a round petal in spring.
    static func leaf(color: CGColor, petal: Bool, size d: CGFloat) -> CGImage {
        let key = "leaf-\(color.components ?? [])-\(petal)-\(d)"
        return draw(key, size: CGSize(width: d, height: d)) { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: .pi / 5)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.8), blur: 1.2, color: CGColor(gray: 0, alpha: 0.3))
            let p = CGMutablePath()
            if petal {
                let w = d * 0.3, h = d * 0.36
                p.move(to: CGPoint(x: 0, y: -h))
                p.addCurve(to: CGPoint(x: 0, y: h * 0.8), control1: CGPoint(x: w * 1.6, y: -h * 0.6), control2: CGPoint(x: w * 1.2, y: h * 1.1))
                p.addLine(to: CGPoint(x: -w * 0.15, y: h * 0.62))
                p.addCurve(to: CGPoint(x: 0, y: -h), control1: CGPoint(x: -w * 1.3, y: h * 1.1), control2: CGPoint(x: -w * 1.6, y: -h * 0.6))
            } else {
                let w = d * 0.2, h = d * 0.42
                p.move(to: CGPoint(x: 0, y: -h))
                p.addQuadCurve(to: CGPoint(x: 0, y: h), control: CGPoint(x: w * 2.2, y: 0))
                p.addQuadCurve(to: CGPoint(x: 0, y: -h), control: CGPoint(x: -w * 2.2, y: 0))
            }
            ctx.addPath(p)
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            // Light from the top left.
            ctx.addPath(p)
            ctx.clip()
            let g = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.25), CGColor(gray: 0, alpha: 0.18)] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: -d / 2, y: d / 2), end: CGPoint(x: d / 2, y: -d / 2), options: [])
            if !petal {
                ctx.resetClip()
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.22))
                ctx.setLineWidth(0.6)
                ctx.move(to: CGPoint(x: 0, y: -d * 0.42))
                ctx.addLine(to: CGPoint(x: 0, y: d * 0.47))
                ctx.strokePath()
            }
        }
    }
}
