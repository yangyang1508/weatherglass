// Draws the app icon. Run: swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// The tile, with the standard macOS margin and a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1B2540))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
// Evening sky seen through glass.
let sky = CGGradient(colorsSpace: space, colors: [color(0x16213D), color(0x34507F), color(0x8C7A99), color(0xE0A57E)] as CFArray,
                     locations: [0, 0.45, 0.78, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Hills.
for (base, amp, freq, hex) in [(0.24, 0.05, 1.6, 0x2C3554), (0.15, 0.04, 2.6, 0x1A2036)] as [(CGFloat, CGFloat, CGFloat, UInt32)] {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: tile.minX, y: tile.minY))
    var x = tile.minX
    while x <= tile.maxX + 4 {
        let u = (x - tile.minX) / tile.width
        p.addLine(to: CGPoint(x: x, y: tile.minY + tile.height * (base + amp * sin(u * .pi * freq + base * 9))))
        x += 4
    }
    p.addLine(to: CGPoint(x: tile.maxX, y: tile.minY))
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(color(hex))
    ctx.fillPath()
}

// Rain streaks.
ctx.setLineCap(.round)
for (x, y, len) in [(250.0, 640.0, 120.0), (420, 760, 90), (610, 720, 130), (760, 560, 100), (330, 430, 110), (720, 380, 80)] as [(CGFloat, CGFloat, CGFloat)] {
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(7)
    ctx.move(to: CGPoint(x: x, y: y))
    ctx.addLine(to: CGPoint(x: x - len * 0.18, y: y - len))
    ctx.strokePath()
}

// Water beads on the glass.
func bead(_ c: CGPoint, _ r: CGFloat) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -r * 0.18), blur: r * 0.35, color: color(0x000000, 0.35))
    let g = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.55), color(0xBFD3EA, 0.25), color(0xFFFFFF, 0.65)] as CFArray,
                       locations: [0, 0.6, 1])!
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r * 1.08, width: r * 2, height: r * 2.16))
    ctx.clip()
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - r * 0.3, y: c.y + r * 0.35), startRadius: 0,
                           endCenter: c, endRadius: r * 1.1, options: [])
    ctx.restoreGState()
    ctx.setFillColor(color(0xFFFFFF, 0.9))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.48, y: c.y + r * 0.28, width: r * 0.34, height: r * 0.26))
}
bead(CGPoint(x: 600, y: 470), 62)
bead(CGPoint(x: 360, y: 580), 34)
bead(CGPoint(x: 735, y: 700), 26)
bead(CGPoint(x: 470, y: 330), 22)

// Snow piled along the top edge of the glass.
let capBase = tile.maxY - 108
let cap = CGMutablePath()
cap.move(to: CGPoint(x: tile.minX, y: tile.maxY))
cap.addLine(to: CGPoint(x: tile.minX, y: capBase + 10))
var x = tile.minX
while x <= tile.maxX + 4 {
    let u = (x - tile.minX) / tile.width
    let y = capBase + 16 * sin(u * .pi * 3.2 + 0.4) + 9 * sin(u * .pi * 8.3) - 18 * pow(abs(u - 0.5) * 2, 3)
    cap.addLine(to: CGPoint(x: x, y: y))
    x += 4
}
cap.addLine(to: CGPoint(x: tile.maxX, y: tile.maxY))
cap.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: color(0x0B1020, 0.45))
ctx.addPath(cap)
ctx.setFillColor(color(0xF4F8FF))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(cap)
ctx.clip()
let snowShade = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xDCE6F5)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(snowShade, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: capBase - 30), options: [])
ctx.restoreGState()

// A thin glass edge.
ctx.addPath(tilePath)
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
