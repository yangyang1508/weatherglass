import Foundation

/// What the sky is doing, simplified from a WMO weather code.
public enum Sky: String, Codable, CaseIterable, Sendable {
    case clear, partlyCloudy, cloudy, fog
    case drizzle, freezingDrizzle, rain, freezingRain, showers
    case snow, snowGrains, snowShowers
    case thunderstorm, hail

    public var title: String {
        switch self {
        case .clear: return "Clear"
        case .partlyCloudy: return "Partly cloudy"
        case .cloudy: return "Cloudy"
        case .fog: return "Fog"
        case .drizzle: return "Drizzle"
        case .freezingDrizzle: return "Freezing drizzle"
        case .rain: return "Rain"
        case .freezingRain: return "Freezing rain"
        case .showers: return "Rain showers"
        case .snow: return "Snow"
        case .snowGrains: return "Snow grains"
        case .snowShowers: return "Snow showers"
        case .thunderstorm: return "Thunderstorm"
        case .hail: return "Thunderstorm with hail"
        }
    }

    /// An SF Symbol name for the menu bar.
    public func symbol(isNight: Bool) -> String {
        switch self {
        case .clear: return isNight ? "moon.stars.fill" : "sun.max.fill"
        case .partlyCloudy: return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .drizzle, .freezingDrizzle: return "cloud.drizzle.fill"
        case .rain, .freezingRain: return "cloud.rain.fill"
        case .showers: return "cloud.heavyrain.fill"
        case .snow, .snowGrains, .snowShowers: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .hail: return "cloud.hail.fill"
        }
    }
}

/// Current conditions at one place, as reported by Open-Meteo.
public struct Conditions: Codable, Equatable, Sendable {
    public var weatherCode: Int
    /// Air temperature at 2 m, in °C.
    public var temperature: Double
    /// Wind speed at 10 m, in km/h.
    public var windSpeed: Double
    /// The direction the wind comes FROM, in degrees (0 = north, 90 = east).
    public var windDirection: Double
    public var isDay: Bool
    /// Precipitation in the 15 minutes before `observedAt`, in mm.
    public var precipitation: Double
    /// Cloud cover, in percent.
    public var cloudCover: Double
    public var observedAt: Date

    public init(weatherCode: Int, temperature: Double, windSpeed: Double, windDirection: Double,
                isDay: Bool, precipitation: Double, cloudCover: Double, observedAt: Date) {
        self.weatherCode = weatherCode
        self.temperature = temperature
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.isDay = isDay
        self.precipitation = precipitation
        self.cloudCover = cloudCover
        self.observedAt = observedAt
    }

    public var sky: Sky { WMO.sky(for: weatherCode) }
}

/// WMO weather interpretation codes, as used by Open-Meteo.
/// https://open-meteo.com/en/docs (section "WMO Weather interpretation codes")
public enum WMO {
    public static func sky(for code: Int) -> Sky {
        switch code {
        case 0, 1: return .clear
        case 2: return .partlyCloudy
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55: return .drizzle
        case 56, 57: return .freezingDrizzle
        case 61, 63, 65: return .rain
        case 66, 67: return .freezingRain
        case 80, 81, 82: return .showers
        case 71, 73, 75: return .snow
        case 77: return .snowGrains
        case 85, 86: return .snowShowers
        case 95: return .thunderstorm
        case 96, 99: return .hail
        default: return .cloudy
        }
    }

    /// How hard it is coming down, from 0 (nothing) to 1 (the heaviest the code can say).
    public static func intensity(for code: Int) -> Double {
        switch code {
        case 45: return 0.6
        case 48: return 0.8
        case 51: return 0.3
        case 53: return 0.5
        case 55: return 0.8
        case 56: return 0.35
        case 57: return 0.75
        case 61: return 0.35
        case 63: return 0.6
        case 65: return 0.95
        case 66: return 0.4
        case 67: return 0.9
        case 71: return 0.35
        case 73: return 0.6
        case 75: return 0.95
        case 77: return 0.4
        case 80: return 0.4
        case 81: return 0.65
        case 82: return 1.0
        case 85: return 0.45
        case 86: return 0.9
        case 95: return 0.75
        case 96: return 0.8
        case 99: return 1.0
        default: return 0
        }
    }
}
