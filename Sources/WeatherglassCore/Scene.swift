import Foundation

/// What falls from the sky.
public enum Precipitation: String, Codable, CaseIterable, Sendable {
    case none, drizzle, rain, snow, hail
}

/// Leaf colors for windy days, chosen by season.
public enum LeafPalette: String, Codable, CaseIterable, Sendable {
    case spring, summer, autumn, winter, tropical

    /// Seasons flip south of the equator. Near the equator there is no autumn.
    public static func palette(latitude: Double, month: Int) -> LeafPalette {
        if abs(latitude) < 23.5 { return .tropical }
        let m = latitude >= 0 ? month : ((month + 5) % 12) + 1
        switch m {
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        case 9, 10, 11: return .autumn
        default: return .winter
        }
    }
}

/// Everything the effects need to draw one moment of weather.
public struct WeatherScene: Equatable, Sendable {
    public var precipitation: Precipitation
    /// 0 (a few drops) ... 1 (a downpour).
    public var intensity: Double
    public var thunder: Bool
    /// 0 (clear air) ... 1 (thick fog).
    public var fog: Double
    /// Water freezes on the glass (freezing rain or drizzle).
    public var freezing: Bool
    /// Sideways drift in points per second. Positive moves right (wind toward the east).
    public var drift: Double
    public var leaves: Bool
    public var palette: LeafPalette
    public var isNight: Bool
    /// °C. Snow on windows melts above freezing.
    public var temperature: Double

    public init(precipitation: Precipitation = .none, intensity: Double = 0, thunder: Bool = false,
                fog: Double = 0, freezing: Bool = false, drift: Double = 0, leaves: Bool = false,
                palette: LeafPalette = .autumn, isNight: Bool = false, temperature: Double = 10) {
        self.precipitation = precipitation
        self.intensity = intensity
        self.thunder = thunder
        self.fog = fog
        self.freezing = freezing
        self.drift = drift
        self.leaves = leaves
        self.palette = palette
        self.isNight = isNight
        self.temperature = temperature
    }

    public static let calm = WeatherScene()

    /// True when nothing will be drawn.
    public var isCalm: Bool {
        precipitation == .none && !thunder && fog == 0 && !leaves
    }

    /// True when snow on windows should melt.
    public var melts: Bool {
        precipitation != .snow && temperature > 0.5
    }
}

public enum SceneBuilder {
    /// Points per second of sideways drift for each km/h of east-west wind.
    public static let driftPerKmh = 2.5
    public static let maxDrift = 140.0
    /// Below this wind speed (km/h) no leaves blow by.
    public static let leafWind = 24.0

    /// The east-west part of the wind, in km/h. Positive blows toward the east.
    public static func eastward(speed: Double, from direction: Double) -> Double {
        -speed * sin(direction * .pi / 180)
    }

    public static func scene(for c: Conditions, latitude: Double, month: Int) -> WeatherScene {
        let sky = c.sky
        var s = WeatherScene()
        s.intensity = WMO.intensity(for: c.weatherCode)
        s.isNight = !c.isDay
        s.temperature = c.temperature
        s.palette = LeafPalette.palette(latitude: latitude, month: month)
        let drift = eastward(speed: c.windSpeed, from: c.windDirection) * driftPerKmh
        s.drift = min(max(drift, -maxDrift), maxDrift)

        switch sky {
        case .clear, .partlyCloudy, .cloudy:
            s.intensity = 0
        case .fog:
            s.fog = s.intensity
            s.intensity = 0
        case .drizzle:
            s.precipitation = .drizzle
        case .freezingDrizzle:
            s.precipitation = .drizzle
            s.freezing = true
        case .rain, .showers:
            s.precipitation = .rain
        case .freezingRain:
            s.precipitation = .rain
            s.freezing = true
        case .snow, .snowGrains, .snowShowers:
            s.precipitation = .snow
        case .thunderstorm:
            s.precipitation = .rain
            s.thunder = true
        case .hail:
            s.precipitation = .hail
            s.thunder = true
        }

        let lightEnough = s.precipitation == .none || s.precipitation == .drizzle
            || (s.precipitation == .rain && s.intensity < 0.5)
        s.leaves = c.windSpeed >= leafWind && lightEnough && s.fog < 0.5
        return s
    }
}

/// Weather you can try from the menu, whatever it is doing outside.
public enum WeatherPreview: String, CaseIterable, Codable, Sendable {
    case rain, storm, snow, blizzard, drizzle, fog, wind, hail

    public var title: String {
        switch self {
        case .rain: return "Rain"
        case .storm: return "Thunderstorm"
        case .snow: return "Snow"
        case .blizzard: return "Blizzard"
        case .drizzle: return "Drizzle"
        case .fog: return "Fog"
        case .wind: return "Windy"
        case .hail: return "Hail"
        }
    }

    public func scene(palette: LeafPalette, isNight: Bool) -> WeatherScene {
        var s = WeatherScene(palette: palette, isNight: isNight)
        switch self {
        case .rain:
            s.precipitation = .rain; s.intensity = 0.6; s.drift = 25; s.temperature = 12
        case .storm:
            s.precipitation = .rain; s.intensity = 0.95; s.thunder = true; s.drift = 70; s.temperature = 18
        case .snow:
            s.precipitation = .snow; s.intensity = 0.6; s.drift = 12; s.temperature = -3
        case .blizzard:
            s.precipitation = .snow; s.intensity = 1; s.drift = 130; s.temperature = -8
        case .drizzle:
            s.precipitation = .drizzle; s.intensity = 0.55; s.drift = 8; s.temperature = 9
        case .fog:
            s.fog = 0.8; s.temperature = 6
        case .wind:
            s.leaves = true; s.drift = 110; s.temperature = 14
        case .hail:
            s.precipitation = .hail; s.intensity = 0.85; s.thunder = true; s.drift = 30; s.temperature = 8
        }
        return s
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable {
    case celsius, fahrenheit

    /// Fahrenheit where people use it (the US and a few other places).
    public static func preferred(for locale: Locale) -> TemperatureUnit {
        let region: String?
        if #available(macOS 13, *) {
            region = locale.region?.identifier
        } else {
            region = locale.regionCode
        }
        let fahrenheitRegions: Set<String> = ["US", "LR", "MM", "BS", "BZ", "KY", "PW", "FM", "MH", "PR", "GU", "VI", "AS", "MP"]
        return fahrenheitRegions.contains(region ?? "") ? .fahrenheit : .celsius
    }

    /// "26°". Rounds half away from zero. An Int has no negative zero, so -0.4 prints "0°".
    public func format(celsius: Double) -> String {
        let value = self == .celsius ? celsius : celsius * 9 / 5 + 32
        return "\(Int(value.rounded()))°"
    }
}
