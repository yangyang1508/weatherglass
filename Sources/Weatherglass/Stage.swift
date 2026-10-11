import AppKit
import QuartzCore
import WeatherglassCore

/// One transparent, click-through window over one screen, holding every effect layer.
@MainActor
final class Overlay {
    let screen: NSScreen
    let window: NSWindow
    let root = CALayer()
    let fog = FogLayer()
    let precipitation = PrecipitationLayer()
    let caps = SnowCapsLayer()
    let glass = GlassLayer()
    let leaves = LeavesLayer()
    let lightning = LightningLayer()

    /// Our window level. Normal windows sit below it; the menu bar, the Dock and menus sit above it.
    static let level = NSWindow.Level.floating

    init(screen: NSScreen) {
        self.screen = screen
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = Self.level
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.title = "Weatherglass"

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        root.contentsScale = screen.backingScaleFactor
        root.actions = ["bounds": NSNull(), "position": NSNull()]
        view.layer = root
        view.wantsLayer = true
        window.contentView = view
        for l in [fog, precipitation, caps, glass, leaves, lightning] as [CALayer] {
            l.contentsScale = screen.backingScaleFactor
            l.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
            root.addSublayer(l)
        }
        caps.screenFrame = screen.frame
        window.setFrame(screen.frame, display: false)
        layout()
    }

    func layout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = CGRect(origin: .zero, size: screen.frame.size)
        for l in root.sublayers ?? [] { l.frame = b }
        CATransaction.commit()
    }

    func configure(hideInFullScreen: Bool, hideFromCapture: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if !hideInFullScreen { behavior.insert(.fullScreenAuxiliary) }
        window.collectionBehavior = behavior
        window.sharingType = hideFromCapture ? .none : .readOnly
    }

    func close() {
        glass.clear()
        caps.clear()
        window.orderOut(nil)
        window.close()
    }
}

/// Runs the weather on every screen.
@MainActor
final class Stage {
    private(set) var overlays: [Overlay] = []
    private(set) var scene = WeatherScene.calm
    let snow = SnowField()

    /// The user's "Subtle / Normal / Cozy" factor.
    var amount: Double = 1
    /// Speeds up snow piling, so previews and demos do not take ten minutes.
    var accumulationBoost: Double = 1
    /// Windows that hide what is behind them but never hold snow (the demo backdrop).
    var backdropWindows: Set<UInt32> = []
    var hideInFullScreen = true
    var hideFromCapture = false
    var wipeEnabled = true

    private(set) var paused = false
    private var visible = false
    private var tickTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var skipFallsOnce = false
    private var lightningTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    private var lastMouse: (point: CGPoint, time: TimeInterval)?

    init() {
        rebuild()
    }

    /// Recreates the overlays, for example after a display was plugged in.
    func rebuild() {
        for o in overlays { o.close() }
        overlays = NSScreen.screens.map { Overlay(screen: $0) }
        for o in overlays { o.configure(hideInFullScreen: hideInFullScreen, hideFromCapture: hideFromCapture) }
        visible = false
        if !paused { show(scene, prewarm: true) }
    }

    func applyWindowOptions() {
        for o in overlays { o.configure(hideInFullScreen: hideInFullScreen, hideFromCapture: hideFromCapture) }
    }

    var overlayWindowNumbers: Set<UInt32> {
        Set(overlays.map { UInt32($0.window.windowNumber) })
    }

    // MARK: Showing weather

    func show(_ next: WeatherScene, prewarm: Bool = false) {
        let wasSnowing = scene.precipitation == .snow
        scene = next
        guard !paused else { return }
        let precip = next.intensity * amount
        let wantsWindows = !next.isCalm || !snow.isEmpty
        if wantsWindows { reveal() }
        for o in overlays {
            o.precipitation.apply(next, amount: precip, prewarm: prewarm)
            o.glass.apply(next, amount: precip, prewarm: prewarm)
            o.leaves.apply(next, amount: amount)
            o.fog.apply(fog: next.fog * (0.55 + 0.45 * min(amount, 1.2)))
        }
        if wasSnowing && next.precipitation != .snow && accumulationBoost > 1 {
            // Leaving a snow preview: the snow slides off rather than lingering for minutes.
            dropAllSnow()
        }
        scheduleLightning()
        updateTicking()
        updateMouseMonitor()
        if !wantsWindows { concealSoon() }
    }

    private func reveal() {
        hideWork?.cancel()
        hideWork = nil
        guard !visible else { return }
        visible = true
        for o in overlays { o.window.orderFrontRegardless() }
    }

    /// Hides the windows once the last particles have fallen, so a clear day costs nothing.
    private func concealSoon() {
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scene.isCalm, self.snow.isEmpty else { return }
                self.visible = false
                for o in self.overlays {
                    o.glass.clear()
                    o.window.orderOut(nil)
                }
            }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: w)
    }

    func dropAllSnow() {
        let falls = snow.shakeOff()
        for o in overlays {
            o.caps.render([])
            for f in falls { o.caps.drop(f) }
        }
    }

    // MARK: Pausing

    func pause() {
        guard !paused else { return }
        paused = true
        tickTimer?.invalidate(); tickTimer = nil
        lightningTimer?.invalidate(); lightningTimer = nil
        hideWork?.cancel()
        updateMouseMonitor()
        for o in overlays {
            o.precipitation.retire()
            o.glass.clear()
            o.leaves.stop()
            o.fog.apply(fog: 0)
            o.window.orderOut(nil)
        }
        visible = false
    }

    func resume() {
        guard paused else { return }
        paused = false
        skipFallsOnce = true
        show(scene, prewarm: true)
    }

    // MARK: Snow on windows

    private func updateTicking() {
        let needed = !paused && (scene.precipitation == .snow || !snow.isEmpty)
        if needed && tickTimer == nil {
            lastTick = CACurrentMediaTime()
            let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
        } else if !needed {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1)
        lastTick = now
        let hosts = Geometry.snowHosts(windows: WindowTracker.onscreen(), overlayLevel: Overlay.level.rawValue,
                                       excluded: overlayWindowNumbers, nonHosts: backdropWindows, capHeight: 26)
        let snowing = scene.precipitation == .snow
        let rate = snowing ? (0.012 + 0.05 * scene.intensity) * amount * accumulationBoost : 0
        let maxHeight = (12 + 8 * scene.intensity) * min(max(amount, 0.7), 1.3)
        let melt = scene.melts ? (accumulationBoost > 1 ? 0.5 : 0.025) : 0
        var falls = snow.update(hosts: hosts, now: now, dt: dt, snowRate: rate, maxHeight: maxHeight, meltRate: melt)
        if skipFallsOnce {
            skipFallsOnce = false
            falls = []
        }
        let caps = snow.caps
        for o in overlays {
            o.caps.render(caps)
            for f in falls { o.caps.drop(f) }
        }
        if !snowing && snow.isEmpty {
            updateTicking()
            if scene.isCalm { concealSoon() }
        }
    }

    /// Call when the user switches Spaces, so windows left behind keep their snow.
    func spaceChanged() {
        snow.spaceChangedAt = CACurrentMediaTime()
    }

    // MARK: Lightning

    private func scheduleLightning() {
        lightningTimer?.invalidate()
        lightningTimer = nil
        guard scene.thunder, !paused else { return }
        let gap = Double.random(in: 6...20) / max(scene.intensity, 0.4)
        let t = Timer(timeInterval: gap, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.scene.thunder, !self.paused else { return }
                self.strike()
                self.scheduleLightning()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        lightningTimer = t
    }

    func strike() {
        let x = CGFloat.random(in: 0.15...0.85)
        let strength = Float(min(0.5 + 0.5 * amount, 1))
        for o in overlays { o.lightning.flash(strength: strength, at: x) }
    }

    // MARK: Wiping the glass

    private func updateMouseMonitor() {
        let wet = scene.precipitation == .rain || scene.precipitation == .drizzle
        let needed = wipeEnabled && wet && !paused
        if needed && mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
            }
        } else if !needed, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
            lastMouse = nil
        }
    }

    func mouseMoved(to p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastMouse = (p, now) }
        guard let last = lastMouse, now - last.time < 0.1 else { return }
        let speed = hypot(p.x - last.point.x, p.y - last.point.y) / max(now - last.time, 0.001)
        guard speed > 1600 else { return }
        for o in overlays where o.screen.frame.insetBy(dx: -50, dy: -50).contains(p) {
            let origin = o.screen.frame.origin
            o.glass.wipe(from: CGPoint(x: last.point.x - origin.x, y: last.point.y - origin.y),
                         to: CGPoint(x: p.x - origin.x, y: p.y - origin.y))
        }
    }
}
