import AppKit
import SwiftUI
import WeatherglassCore

/// `--demo <weather>`: a made-up desktop with a few real windows, for recording the README video
/// without showing anyone's own screen. The windows are real, so the snow on them is real too.
@MainActor
final class Demo {
    private let stage: Stage
    private var backdrop: NSWindow?
    private var notes: NSWindow?
    private var music: NSWindow?
    private var editor: NSWindow?
    private var timers: [Timer] = []

    init(stage: Stage) {
        self.stage = stage
    }

    func run(_ kind: WeatherPreview, boost: Double) {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame

        let back = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        back.contentView = BackdropView()
        back.isReleasedWhenClosed = false
        back.collectionBehavior = [.canJoinAllSpaces, .stationary]
        back.orderFrontRegardless()
        backdrop = back
        stage.backdropWindows = [UInt32(back.windowNumber)]
        stage.accumulationBoost = boost

        editor = window("Weather.swift", CodeCard(),
                        CGRect(x: f.minX + f.width * 0.42, y: f.minY + f.height * 0.12, width: 600, height: 380))
        notes = window("Notes", NotesCard(),
                       CGRect(x: f.minX + f.width * 0.08, y: f.minY + f.height * 0.30, width: 380, height: 300))
        music = window("Now Playing", MusicCard(),
                       CGRect(x: f.minX + f.width * 0.50, y: f.minY + f.height * 0.68, width: 380, height: 150))

        switch kind {
        case .snow, .blizzard:
            // Let the snow pile up, then move one window and hide another so it falls off.
            // Short, so that one recording of about ten seconds shows all of it.
            after(5) { me in me.slide(me.notes, by: CGVector(dx: 140, dy: -90)) }
            after(7.5) { me in me.music?.orderOut(nil) }
            after(9.5) { me in me.music?.orderFront(nil) }
        case .rain, .drizzle, .storm:
            after(3) { me in me.wipe(from: 0.22, to: 0.62, y: 0.55) }
            after(6.5) { me in me.wipe(from: 0.70, to: 0.30, y: 0.35) }
            if kind == .storm {
                after(1.5) { me in me.stage.strike() }
                after(7) { me in me.stage.strike() }
            }
        default:
            break
        }
    }

    private func window<V: View>(_ title: String, _ view: V, _ frame: CGRect) -> NSWindow {
        // The title bar is drawn by the demo. While a window is recorded, macOS 26 puts a
        // "being shared" badge over the real window buttons, and the badge would show in the video.
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.title = title
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.contentView = NSHostingView(rootView: WindowChrome(title: title, content: view))
        w.isReleasedWhenClosed = false
        w.setFrame(frame, display: false)
        w.orderFrontRegardless()
        return w
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping (Demo) -> Void) {
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { body(self) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    /// Moves a window the way a person drags it: quickly, in small steps.
    private func slide(_ w: NSWindow?, by d: CGVector) {
        guard let w else { return }
        let start = w.frame.origin
        let steps = 24
        for i in 1...steps {
            let t = Timer(timeInterval: Double(i) / 60, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let p = Double(i) / Double(steps)
                    let e = p * p * (3 - 2 * p)
                    w.setFrameOrigin(CGPoint(x: start.x + d.dx * e, y: start.y + d.dy * e))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
    }

    /// Feeds a fast zigzag of pointer positions to the wipe, as if someone shook the mouse.
    private func wipe(from x0: Double, to x1: Double, y: Double) {
        guard let s = NSScreen.main?.frame else { return }
        let steps = 40
        for i in 0...steps {
            let t = Timer(timeInterval: Double(i) / 60, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    let p = Double(i) / Double(steps)
                    let x = s.minX + s.width * (x0 + (x1 - x0) * p)
                    let wobble = sin(p * .pi * 6) * 70
                    self?.stage.mouseMoved(to: CGPoint(x: x, y: s.minY + s.height * y + wobble))
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timers.append(t)
        }
    }
}

/// A quiet evening landscape, so the weather has something to fall in front of.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        let sky = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.07, green: 0.10, blue: 0.20, alpha: 1),
            CGColor(red: 0.20, green: 0.27, blue: 0.43, alpha: 1),
            CGColor(red: 0.55, green: 0.47, blue: 0.52, alpha: 1),
            CGColor(red: 0.82, green: 0.60, blue: 0.48, alpha: 1),
        ] as CFArray, locations: [0, 0.45, 0.75, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: b.maxY), end: CGPoint(x: 0, y: b.minY + b.height * 0.25), options: [.drawsAfterEndLocation])

        let layers: [(CGFloat, CGFloat, CGFloat, CGColor)] = [
            (0.42, 0.10, 1.3, CGColor(red: 0.30, green: 0.30, blue: 0.42, alpha: 1)),
            (0.30, 0.08, 2.1, CGColor(red: 0.19, green: 0.21, blue: 0.32, alpha: 1)),
            (0.17, 0.06, 3.4, CGColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1)),
        ]
        for (i, (base, amp, freq, color)) in layers.enumerated() {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: b.minX, y: b.minY))
            var x = b.minX
            while x <= b.maxX + 8 {
                let u = Double(x / b.width)
                let h = sin(u * .pi * Double(freq) + Double(i) * 1.7) * 0.6
                    + sin(u * .pi * Double(freq) * 2.3 + Double(i)) * 0.4
                path.addLine(to: CGPoint(x: x, y: b.minY + b.height * (base + amp * CGFloat(h))))
                x += 8
            }
            path.addLine(to: CGPoint(x: b.maxX, y: b.minY))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color)
            ctx.fillPath()
        }
    }
}

/// A window frame like the system one: three buttons, a title, rounded corners.
private struct WindowChrome<Content: View>: View {
    let title: String
    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                    Circle().fill(color).frame(width: 12, height: 12)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NotesCard: View {
    private let items = [("Pick up the jacket from the cleaner", true),
                         ("Book the cabin for the weekend", true),
                         ("Buy hot chocolate", false),
                         ("Call Grandma", false),
                         ("Water the plants (not today)", false)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saturday").font(.title2.weight(.bold))
            ForEach(items, id: \.0) { text, done in
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.orange : Color.secondary)
                    Text(text).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MusicCard: View {
    var body: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Image(systemName: "cloud.rain.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text("Window Seat").font(.headline)
                Text("Rainy Afternoon Sessions").font(.subheadline).foregroundStyle(.secondary)
                ProgressView(value: 0.36).tint(.teal)
                HStack(spacing: 22) {
                    Image(systemName: "backward.fill")
                    Image(systemName: "pause.fill").font(.title3)
                    Image(systemName: "forward.fill")
                }
                .foregroundStyle(.primary)
            }
        }
        .padding(18)
    }
}

private struct CodeCard: View {
    private let code = """
    func scene(for c: Conditions) -> WeatherScene {
        var s = WeatherScene()
        switch c.sky {
        case .rain, .showers:
            s.precipitation = .rain
        case .snow, .snowShowers:
            s.precipitation = .snow
        case .thunderstorm:
            s.precipitation = .rain
            s.thunder = true
        default:
            break
        }
        s.intensity = WMO.intensity(for: c.weatherCode)
        s.drift = drift(c.windSpeed, c.windDirection)
        return s
    }
    """

    var body: some View {
        ScrollView {
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color(red: 0.86, green: 0.88, blue: 0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(Color(red: 0.12, green: 0.13, blue: 0.16))
    }
}
