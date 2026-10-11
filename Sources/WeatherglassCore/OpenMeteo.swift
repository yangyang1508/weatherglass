import Foundation

public struct Coordinates: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Rounded to 0.1° (about 11 km). This is all that ever leaves the Mac.
    public var rounded: Coordinates {
        Coordinates(latitude: (latitude * 10).rounded() / 10, longitude: (longitude * 10).rounded() / 10)
    }
}

/// A place the user picked, or the current location.
public struct Place: Codable, Equatable, Sendable {
    public var name: String
    /// "Hanoi, Vietnam" style detail for menus. May be empty.
    public var detail: String
    public var coordinates: Coordinates

    public init(name: String, detail: String, coordinates: Coordinates) {
        self.name = name
        self.detail = detail
        self.coordinates = coordinates
    }
}

public enum OpenMeteoError: Error, Equatable {
    case badResponse
    case server(String)
}

/// The free Open-Meteo API. No key, no account. https://open-meteo.com
public enum OpenMeteo {
    static let fields = "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day,precipitation,cloud_cover"

    public static func forecastURL(for coordinates: Coordinates) -> URL {
        let c = coordinates.rounded
        var u = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        u.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", c.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", c.longitude)),
            URLQueryItem(name: "current", value: fields),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return u.url!
    }

    /// nil for a blank query.
    public static func searchURL(query: String, language: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return nil }
        var u = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        u.queryItems = [
            URLQueryItem(name: "name", value: q),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "format", value: "json"),
        ]
        return u.url
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature_2m: Double
            let weather_code: Int
            let wind_speed_10m: Double
            let wind_direction_10m: Double
            let is_day: Int
            let precipitation: Double?
            let cloud_cover: Double?
        }
        let current: Current?
        let error: Bool?
        let reason: String?
    }

    public static func decodeConditions(_ data: Data) throws -> Conditions {
        let r: ForecastResponse
        do {
            r = try JSONDecoder().decode(ForecastResponse.self, from: data)
        } catch {
            throw OpenMeteoError.badResponse
        }
        if r.error == true { throw OpenMeteoError.server(r.reason ?? "unknown error") }
        guard let c = r.current else { throw OpenMeteoError.badResponse }
        return Conditions(
            weatherCode: c.weather_code,
            temperature: c.temperature_2m,
            windSpeed: c.wind_speed_10m,
            windDirection: c.wind_direction_10m,
            isDay: c.is_day == 1,
            precipitation: c.precipitation ?? 0,
            cloudCover: c.cloud_cover ?? 0,
            observedAt: parseGMT(c.time) ?? Date()
        )
    }

    /// "2026-10-11T13:30" in GMT.
    static func parseGMT(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: s)
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    public static func decodePlaces(_ data: Data) throws -> [Place] {
        let r: SearchResponse
        do {
            r = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw OpenMeteoError.badResponse
        }
        return (r.results ?? []).map { x in
            var parts: [String] = []
            if let a = x.admin1, !a.isEmpty, a != x.name { parts.append(a) }
            if let c = x.country, !c.isEmpty { parts.append(c) }
            return Place(name: x.name, detail: parts.joined(separator: ", "),
                         coordinates: Coordinates(latitude: x.latitude, longitude: x.longitude))
        }
    }
}
