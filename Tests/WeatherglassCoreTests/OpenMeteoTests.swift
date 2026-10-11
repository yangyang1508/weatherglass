import XCTest
@testable import WeatherglassCore

final class OpenMeteoTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testDecodesARealForecast() throws {
        let c = try OpenMeteo.decodeConditions(fixture("forecast-hanoi"))
        XCTAssertEqual(c.weatherCode, 0)
        XCTAssertEqual(c.temperature, 26.2)
        XCTAssertEqual(c.windSpeed, 6.2)
        XCTAssertEqual(c.windDirection, 147)
        XCTAssertFalse(c.isDay)
        XCTAssertEqual(c.precipitation, 0)
        XCTAssertEqual(c.cloudCover, 1)
        // 2026-10-11T13:30 GMT
        XCTAssertEqual(c.observedAt.timeIntervalSince1970, 1_791_725_400)
    }

    func testReportsServerErrors() throws {
        XCTAssertThrowsError(try OpenMeteo.decodeConditions(fixture("forecast-error"))) { e in
            XCTAssertEqual(e as? OpenMeteoError, .server("Latitude must be in range of -90 to 90°. Given: 999.0."))
        }
        XCTAssertThrowsError(try OpenMeteo.decodeConditions(Data("<html>".utf8))) { e in
            XCTAssertEqual(e as? OpenMeteoError, .badResponse)
        }
        XCTAssertThrowsError(try OpenMeteo.decodeConditions(Data("{}".utf8))) { e in
            XCTAssertEqual(e as? OpenMeteoError, .badResponse)
        }
    }

    func testOnlyRoundedCoordinatesLeaveTheMac() throws {
        let url = OpenMeteo.forecastURL(for: Coordinates(latitude: 21.0245, longitude: 105.84117))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(q["latitude"], "21.0")
        XCTAssertEqual(q["longitude"], "105.8")
        XCTAssertEqual(q["timezone"], "GMT")
        XCTAssertEqual(q["current"], "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day,precipitation,cloud_cover")

        let sydney = Coordinates(latitude: -33.8688, longitude: 151.2093).rounded
        XCTAssertEqual(sydney.latitude, -33.9, accuracy: 1e-9)
        XCTAssertEqual(sydney.longitude, 151.2, accuracy: 1e-9)
    }

    func testSearchURL() throws {
        XCTAssertNil(OpenMeteo.searchURL(query: "   ", language: "en"))
        XCTAssertNil(OpenMeteo.searchURL(query: "a", language: "en"))
        let url = try XCTUnwrap(OpenMeteo.searchURL(query: "  Hồ Chí Minh ", language: "vi"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Hồ Chí Minh")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, "vi")
        XCTAssertEqual(url.host, "geocoding-api.open-meteo.com")
    }

    func testDecodesPlaces() throws {
        let places = try OpenMeteo.decodePlaces(fixture("search-hanoi"))
        XCTAssertGreaterThanOrEqual(places.count, 2)
        XCTAssertEqual(places[0].name, "Hanoi")
        XCTAssertEqual(places[0].detail, "Vietnam", "admin1 equal to the name is not repeated")
        XCTAssertEqual(places[0].coordinates.latitude, 21.0245)
        XCTAssertEqual(try OpenMeteo.decodePlaces(fixture("search-empty")), [])
        XCTAssertThrowsError(try OpenMeteo.decodePlaces(Data("nope".utf8)))
    }
}
