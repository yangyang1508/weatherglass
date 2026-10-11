import AppKit
import IOKit.ps
import ServiceManagement

/// Why the weather is paused. Any reason pauses it.
struct PauseReasons: OptionSet {
    let rawValue: Int
    static let disabled = PauseReasons(rawValue: 1 << 0)
    static let asleep = PauseReasons(rawValue: 1 << 1)
    static let screensAsleep = PauseReasons(rawValue: 1 << 2)
    static let locked = PauseReasons(rawValue: 1 << 3)
    static let battery = PauseReasons(rawValue: 1 << 4)
}

enum Power {
    /// True when the Mac runs on its battery.
    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns an error message, or nil on success.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Watches sleep, wake, screen lock, Space changes, display changes and the power source.
@MainActor
final class SystemWatcher {
    var onPause: ((PauseReasons, Bool) -> Void)?
    var onSpaceChange: (() -> Void)?
    var onScreensChange: (() -> Void)?
    var onWake: (() -> Void)?
    var watchBattery = false {
        didSet { checkBattery() }
    }

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var batteryTimer: Timer?
    private var screensWork: DispatchWorkItem?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { $0.onPause?(.asleep, true) }
        observe(ws, NSWorkspace.didWakeNotification) {
            $0.onPause?(.asleep, false)
            $0.onWake?()
        }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.onPause?(.screensAsleep, true) }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.onPause?(.screensAsleep, false) }
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { $0.onSpaceChange?() }
        let dn = DistributedNotificationCenter.default()
        observe(dn, Notification.Name("com.apple.screenIsLocked")) { $0.onPause?(.locked, true) }
        observe(dn, Notification.Name("com.apple.screenIsUnlocked")) { $0.onPause?(.locked, false) }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { me in
            // Displays often change in bursts (lid, mirroring). Wait for them to settle.
            me.screensWork?.cancel()
            let w = DispatchWorkItem { [weak me] in
                MainActor.assumeIsolated { me?.onScreensChange?() }
            }
            me.screensWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
        }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBattery() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        batteryTimer = t
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping (SystemWatcher) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                body(self)
            }
        }
        tokens.append((center, token))
    }

    private func checkBattery() {
        onPause?(.battery, watchBattery && Power.onBattery)
    }
}
