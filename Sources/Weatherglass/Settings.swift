import Foundation
import WeatherglassCore

/// How much weather to show. Multiplies the real intensity.
enum Amount: String, CaseIterable {
    case subtle, normal, cozy

    var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .cozy: return "Cozy"
        }
    }

    var factor: Double {
        switch self {
        case .subtle: return 0.55
        case .normal: return 1
        case .cozy: return 1.5
        }
    }
}

/// User preferences, kept in UserDefaults.
@MainActor
final class Settings {
    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) {
        d = defaults
        d.register(defaults: [
            Key.enabled: true,
            Key.amount: Amount.normal.rawValue,
            Key.showTemperature: true,
            Key.hideInFullScreen: true,
            Key.pauseOnBattery: false,
            Key.hideFromCapture: false,
            Key.wipe: true,
        ])
    }

    private enum Key {
        static let enabled = "enabled"
        static let amount = "amount"
        static let place = "place"
        static let useCurrentLocation = "useCurrentLocation"
        static let unit = "unit"
        static let showTemperature = "showTemperature"
        static let hideInFullScreen = "hideInFullScreen"
        static let pauseOnBattery = "pauseOnBattery"
        static let hideFromCapture = "hideFromCapture"
        static let wipe = "wipe"
        static let lastConditions = "lastConditions"
    }

    var enabled: Bool {
        get { d.bool(forKey: Key.enabled) }
        set { d.set(newValue, forKey: Key.enabled) }
    }

    var amount: Amount {
        get { Amount(rawValue: d.string(forKey: Key.amount) ?? "") ?? .normal }
        set { d.set(newValue.rawValue, forKey: Key.amount) }
    }

    var place: Place? {
        get { decode(Place.self, Key.place) }
        set { encode(newValue, Key.place) }
    }

    var useCurrentLocation: Bool {
        get { d.bool(forKey: Key.useCurrentLocation) }
        set { d.set(newValue, forKey: Key.useCurrentLocation) }
    }

    var unit: TemperatureUnit {
        get { TemperatureUnit(rawValue: d.string(forKey: Key.unit) ?? "") ?? .preferred(for: .current) }
        set { d.set(newValue.rawValue, forKey: Key.unit) }
    }

    var showTemperature: Bool {
        get { d.bool(forKey: Key.showTemperature) }
        set { d.set(newValue, forKey: Key.showTemperature) }
    }

    var hideInFullScreen: Bool {
        get { d.bool(forKey: Key.hideInFullScreen) }
        set { d.set(newValue, forKey: Key.hideInFullScreen) }
    }

    var pauseOnBattery: Bool {
        get { d.bool(forKey: Key.pauseOnBattery) }
        set { d.set(newValue, forKey: Key.pauseOnBattery) }
    }

    /// Keep the weather out of screenshots, recordings and screen sharing.
    var hideFromCapture: Bool {
        get { d.bool(forKey: Key.hideFromCapture) }
        set { d.set(newValue, forKey: Key.hideFromCapture) }
    }

    /// Shake the pointer to wipe raindrops off the glass.
    var wipe: Bool {
        get { d.bool(forKey: Key.wipe) }
        set { d.set(newValue, forKey: Key.wipe) }
    }

    /// The last good report, so the app has something to show before the network is up.
    var lastConditions: Conditions? {
        get { decode(Conditions.self, Key.lastConditions) }
        set { encode(newValue, Key.lastConditions) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            d.set(data, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
    }
}
