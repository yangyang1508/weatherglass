import AppKit
import WeatherglassCore

@main
enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = AppController(options: LaunchOptions(CommandLine.arguments))
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Flags for testing and for recording the demo. Normal users never pass any.
struct LaunchOptions {
    var preview: WeatherPreview?
    var demo: WeatherPreview?
    var quitAfter: TimeInterval?
    var boost: Double?
    /// Use a separate settings domain, so tests never touch the user's settings.
    var suite: String?
    /// Pick a place at launch, as if chosen in the window: `--place "Hanoi,21.03,105.85"`.
    var place: Place?

    init(_ args: [String]) {
        var i = 1
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--preview": preview = Self.weather(value())
            case "--demo": demo = Self.weather(value())
            case "--quit-after": quitAfter = value().flatMap(TimeInterval.init)
            case "--boost": boost = value().flatMap(Double.init)
            case "--settings": suite = value()
            case "--place": place = value().flatMap(Self.place(from:))
            default: break
            }
            i += 1
        }
    }

    /// A typo should not quietly start the app the normal way, so an unknown name stops it.
    private static func weather(_ name: String?) -> WeatherPreview {
        if let name, let w = WeatherPreview(rawValue: name) { return w }
        let names = WeatherPreview.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("Unknown weather \"\(name ?? "")\". Use one of: \(names).\n".utf8))
        exit(2)
    }

    private static func place(from text: String) -> Place? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3, let lat = Double(parts[1]), let lon = Double(parts[2]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return Place(name: parts[0], detail: "", coordinates: Coordinates(latitude: lat, longitude: lon))
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private let settings: Settings
    private var stage: Stage!
    private let weather = WeatherService()
    private let locator = LocationProvider()
    private let placeWindow = PlaceWindowController()
    private let system = SystemWatcher()
    private let toast = Toast()
    private var statusItem: NSStatusItem!
    private var demo: Demo?

    private var conditions: Conditions?
    private var preview: WeatherPreview?
    private var pauseReasons: PauseReasons = []
    private var locating = false
    /// The first-run window is open, with snow falling around it.
    private var welcoming = false
    /// A place was just chosen; say what the weather is when the first report comes in.
    private var announce = false

    init(options: LaunchOptions) {
        self.options = options
        if let suite = options.suite, let d = UserDefaults(suiteName: suite) {
            settings = Settings(defaults: d)
        } else {
            settings = Settings()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        stage = Stage()
        applySettingsToStage()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = .removalAllowed
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        weather.onUpdate = { [weak self] c in self?.received(c) }
        weather.onStateChange = { [weak self] in self?.updateStatusItem() }

        system.onPause = { [weak self] reason, on in self?.setPaused(reason, on) }
        system.onSpaceChange = { [weak self] in self?.stage.spaceChanged() }
        system.onScreensChange = { [weak self] in self?.stage.rebuild() }
        system.onWake = { [weak self] in self?.weather.refresh() }
        system.watchBattery = settings.pauseOnBattery
        system.start()
        if !settings.enabled { pauseReasons.insert(.disabled) }

        conditions = settings.lastConditions
        if let d = options.demo {
            demo = Demo(stage: stage)
            demo?.run(d, boost: options.boost ?? 30)
            preview = d
        } else if let p = options.preview {
            preview = p
            if let b = options.boost { stage.accumulationBoost = b }
        }
        startTracking()
        refreshScene(prewarm: true)
        if pauseReasons.isEmpty { stage.resume() } else { stage.pause() }

        if let p = options.place {
            pick(p)
        } else if options.demo == nil && options.preview == nil && settings.place == nil && !settings.useCurrentLocation {
            welcome()
        }
        if let q = options.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + q) { NSApp.terminate(nil) }
        }
    }

    // MARK: Weather

    private func startTracking() {
        if settings.useCurrentLocation {
            locate()
        } else {
            weather.track(settings.place?.coordinates)
        }
    }

    private func locate() {
        locating = true
        updateStatusItem()
        locator.locate { [weak self] result in
            guard let self else { return }
            self.locating = false
            switch result {
            case .success(let c):
                self.settings.useCurrentLocation = true
                self.settings.place = Place(name: "Current Location", detail: "", coordinates: c)
                self.announce = true
                self.weather.track(c)
            case .failure(let f):
                self.settings.useCurrentLocation = false
                self.updateStatusItem()
                self.alert(f == .denied ? "Weatherglass can’t see your location."
                                        : "Your location isn’t available right now.",
                           f == .denied ? "You can allow it in System Settings → Privacy & Security → Location Services, or choose a city instead."
                                        : "Choose a city instead, or try again later.")
                if self.settings.place == nil { self.choosePlace() }
            }
        }
    }

    private func received(_ c: Conditions) {
        conditions = c
        settings.lastConditions = c
        refreshScene(prewarm: false)
        if announce {
            announce = false
            announceCalm()
        }
    }

    /// On a clear day nothing appears, which can look like the app is broken. Say so once.
    private func announceCalm() {
        guard preview == nil, currentScene().isCalm, let c = conditions, let p = settings.place else { return }
        let place = settings.useCurrentLocation ? "your area" : p.name
        toast.show("\(c.sky.title) in \(place) right now",
                   "Weatherglass waits quietly until it rains, snows, or the fog rolls in. "
                   + "To see it now, click its icon in the menu bar and choose Preview.")
    }

    private func currentScene() -> WeatherScene {
        let latitude = settings.place?.coordinates.latitude ?? 45
        let month = Calendar.current.component(.month, from: Date())
        if let p = preview {
            return p.scene(palette: LeafPalette.palette(latitude: latitude, month: month),
                           isNight: conditions.map { !$0.isDay } ?? false)
        }
        guard let c = conditions, settings.place != nil else { return .calm }
        return SceneBuilder.scene(for: c, latitude: latitude, month: month)
    }

    private func refreshScene(prewarm: Bool) {
        stage.show(currentScene(), prewarm: prewarm)
        // Set after `show`: when a preview ends, `show` still sees the boost and clears the preview's snow.
        if options.demo == nil {
            stage.accumulationBoost = preview != nil ? (options.boost ?? 6) : 1
        }
        updateStatusItem()
    }

    private func applySettingsToStage() {
        stage.amount = settings.amount.factor
        stage.hideInFullScreen = settings.hideInFullScreen
        stage.hideFromCapture = settings.hideFromCapture
        stage.wipeEnabled = settings.wipe
        stage.applyWindowOptions()
    }

    private func setPaused(_ reason: PauseReasons, _ on: Bool) {
        let before = pauseReasons
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        guard before.isEmpty != pauseReasons.isEmpty else { return }
        if pauseReasons.isEmpty {
            stage.resume()
        } else {
            stage.pause()
        }
        updateStatusItem()
    }

    // MARK: First run and places

    private func welcome() {
        // Let it snow on the welcome window while the user picks a place.
        welcoming = true
        preview = .snow
        refreshScene(prewarm: true)
        placeWindow.show(welcome: true, onPick: { [weak self] p in
            self?.pick(p)
        }, onUseLocation: { [weak self] in
            self?.endWelcome()
            self?.locate()
        }, onDismiss: { [weak self] in
            self?.endWelcome()
        })
    }

    private func endWelcome() {
        guard welcoming else { return }
        welcoming = false
        preview = nil
        refreshScene(prewarm: false)
    }

    private func pick(_ p: Place) {
        settings.place = p
        settings.useCurrentLocation = false
        conditions = nil
        settings.lastConditions = nil
        announce = true
        endWelcome()
        refreshScene(prewarm: false)
        weather.track(p.coordinates)
    }

    private func choosePlace() {
        placeWindow.show(welcome: false, onPick: { [weak self] p in self?.pick(p) },
                         onUseLocation: { [weak self] in self?.locate() })
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let sky = conditions?.sky ?? .partlyCloudy
        let isNight = conditions.map { !$0.isDay } ?? false
        let symbol = preview.map(Self.symbol(for:)) ?? sky.symbol(isNight: isNight)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: sky.title)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        if settings.showTemperature, let c = conditions, settings.place != nil {
            button.title = " " + settings.unit.format(celsius: c.temperature)
        } else {
            button.title = ""
        }
        button.appearsDisabled = !pauseReasons.isEmpty
        button.toolTip = "Weatherglass"
    }

    static func symbol(for p: WeatherPreview) -> String {
        switch p {
        case .rain: return "cloud.rain.fill"
        case .storm: return "cloud.bolt.rain.fill"
        case .snow, .blizzard: return "cloud.snow.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .fog: return "cloud.fog.fill"
        case .wind: return "wind"
        case .hail: return "cloud.hail.fill"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in headerItems() { menu.addItem(item) }
        menu.addItem(.separator())

        menu.addItem(toggle("Show Weather on Screen", settings.enabled) { me in
            me.settings.enabled.toggle()
            me.setPaused(.disabled, !me.settings.enabled)
        })
        menu.addItem(submenu("Amount", Amount.allCases.map { a in
            choice(a.title, settings.amount == a) { me in
                me.settings.amount = a
                me.applySettingsToStage()
                me.refreshScene(prewarm: false)
            }
        }))
        var previews = [choice("Real Weather", preview == nil) { me in
            me.preview = nil
            me.refreshScene(prewarm: false)
        }, NSMenuItem.separator()]
        previews += WeatherPreview.allCases.map { p in
            choice(p.title, preview == p) { me in
                me.preview = p
                me.refreshScene(prewarm: true)
            }
        }
        menu.addItem(submenu("Preview", previews))
        menu.addItem(.separator())

        var places: [NSMenuItem] = [
            choice("Current Location", settings.useCurrentLocation) { me in me.locate() },
        ]
        if let p = settings.place, !settings.useCurrentLocation {
            places.append(choice(p.name, true) { _ in })
        }
        places.append(.separator())
        places.append(action("Choose a Place…") { me in me.choosePlace() })
        menu.addItem(submenu("Location", places))

        menu.addItem(submenu("Temperature", [
            choice("Celsius (°C)", settings.unit == .celsius) { me in me.settings.unit = .celsius; me.updateStatusItem() },
            choice("Fahrenheit (°F)", settings.unit == .fahrenheit) { me in me.settings.unit = .fahrenheit; me.updateStatusItem() },
            .separator(),
            toggle("Show in Menu Bar", settings.showTemperature) { me in me.settings.showTemperature.toggle(); me.updateStatusItem() },
        ]))
        menu.addItem(submenu("Options", [
            toggle("Hide When an App Is Full Screen", settings.hideInFullScreen) { me in
                me.settings.hideInFullScreen.toggle(); me.applySettingsToStage()
            },
            toggle("Pause on Battery Power", settings.pauseOnBattery) { me in
                me.settings.pauseOnBattery.toggle(); me.system.watchBattery = me.settings.pauseOnBattery
            },
            toggle("Hide from Screenshots and Screen Sharing", settings.hideFromCapture) { me in
                me.settings.hideFromCapture.toggle(); me.applySettingsToStage()
            },
            toggle("Shake the Pointer to Wipe Rain", settings.wipe) { me in
                me.settings.wipe.toggle(); me.applySettingsToStage(); me.refreshScene(prewarm: false)
            },
            .separator(),
            toggle("Open at Login", LoginItem.isEnabled) { me in
                if let error = LoginItem.set(!LoginItem.isEnabled) {
                    me.alert("Couldn’t change the login item.", error)
                }
            },
        ]))
        menu.addItem(.separator())
        let refresh = action("Refresh Now") { me in me.weather.refresh() }
        refresh.isEnabled = settings.place != nil
        menu.addItem(refresh)
        menu.addItem(action("About Weatherglass") { me in me.about() })
        let quit = NSMenuItem(title: "Quit Weatherglass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func headerItems() -> [NSMenuItem] {
        var lines: [String] = []
        if let p = settings.place {
            lines.append(p.name)
            if let c = conditions {
                let wind = Int(c.windSpeed.rounded())
                lines.append("\(c.sky.title) · \(settings.unit.format(celsius: c.temperature)) · wind \(wind) km/h")
            }
        } else {
            lines.append("No place chosen yet")
        }
        if let p = preview {
            lines.append("Previewing \(p.title.lowercased())")
        }
        if locating {
            lines.append("Finding your location…")
        } else {
            switch weather.state {
            case .loading: lines.append("Updating…")
            case .failed(let why): lines.append("\(why) — showing the last report, retrying soon")
            case .ok(let date):
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .full
                lines.append("Updated \(f.localizedString(for: date, relativeTo: Date()))")
            case .idle: break
            }
        }
        if !pauseReasons.isEmpty && settings.enabled {
            lines.append(pauseReasons.contains(.battery) ? "Paused on battery power" : "Paused")
        }
        return lines.enumerated().map { i, text in
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            if i == 0 {
                item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            }
            return item
        }
    }

    // Menu item helpers: each item runs a closure with the controller.
    private final class Handler: NSObject {
        let body: (AppController) -> Void
        weak var owner: AppController?
        init(_ owner: AppController, _ body: @escaping (AppController) -> Void) {
            self.owner = owner
            self.body = body
        }

        @objc func run(_ sender: Any?) {
            MainActor.assumeIsolated {
                if let o = owner { body(o) }
            }
        }
    }

    private func action(_ title: String, _ body: @escaping (AppController) -> Void) -> NSMenuItem {
        let h = Handler(self, body)
        let item = NSMenuItem(title: title, action: #selector(Handler.run(_:)), keyEquivalent: "")
        item.target = h
        item.representedObject = h
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ body: @escaping (AppController) -> Void) -> NSMenuItem {
        let item = action(title, body)
        item.state = on ? .on : .off
        return item
    }

    private func choice(_ title: String, _ on: Bool, _ body: @escaping (AppController) -> Void) -> NSMenuItem {
        toggle(title, on, body)
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        for i in items { m.addItem(i) }
        item.submenu = m
        return item
    }

    private func about() {
        let credits = NSMutableAttributedString(string: "The real weather outside, on your screen.\n\nWeather data by Open-Meteo.com (CC BY 4.0).\n")
        credits.append(NSAttributedString(string: AppInfo.repository, attributes: [.link: URL(string: AppInfo.repository)!]))
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
