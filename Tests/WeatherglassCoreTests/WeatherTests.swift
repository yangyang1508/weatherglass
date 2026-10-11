import AppKit
import XCTest
@testable import WeatherglassCore

final class WeatherTests: XCTestCase {
    func testEveryDocumentedCodeMapsToTheRightSky() {
        let expected: [Int: Sky] = [
            0: .clear, 1: .clear, 2: .partlyCloudy, 3: .cloudy, 45: .fog, 48: .fog,
            51: .drizzle, 53: .drizzle, 55: .drizzle, 56: .freezingDrizzle, 57: .freezingDrizzle,
            61: .rain, 63: .rain, 65: .rain, 66: .freezingRain, 67: .freezingRain,
            71: .snow, 73: .snow, 75: .snow, 77: .snowGrains, 80: .showers, 81: .showers, 82: .showers,
            85: .snowShowers, 86: .snowShowers, 95: .thunderstorm, 96: .hail, 99: .hail,
        ]
        for (code, sky) in expected {
            XCTAssertEqual(WMO.sky(for: code), sky, "code \(code)")
        }
        XCTAssertEqual(WMO.sky(for: 42), .cloudy, "unknown codes fall back to a calm sky")
    }

    func testIntensityGrowsWithEachFamilyAndStaysInRange() {
        for family in [[51, 53, 55], [61, 63, 65], [71, 73, 75], [80, 81, 82], [96, 99]] {
            let values = family.map(WMO.intensity(for:))
            XCTAssertEqual(values, values.sorted(), "family \(family)")
            XCTAssertEqual(Set(values).count, values.count, "family \(family) has distinct steps")
        }
        for code in 0...100 {
            let v = WMO.intensity(for: code)
            XCTAssert((0...1).contains(v), "code \(code) gave \(v)")
        }
        XCTAssertEqual(WMO.intensity(for: 0), 0)
    }

    func testEverySymbolExistsInSFSymbols() {
        for sky in Sky.allCases {
            for night in [false, true] {
                let name = sky.symbol(isNight: night)
                XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), "\(sky) → \(name)")
            }
            XCTAssertFalse(sky.title.isEmpty)
        }
    }

    func conditions(code: Int, temp: Double = 10, wind: Double = 5, from dir: Double = 270, day: Bool = true) -> Conditions {
        Conditions(weatherCode: code, temperature: temp, windSpeed: wind, windDirection: dir, isDay: day,
                   precipitation: 0, cloudCover: 50, observedAt: Date(timeIntervalSince1970: 0))
    }

    func testScenesForEachKindOfWeather() {
        let storm = SceneBuilder.scene(for: conditions(code: 95), latitude: 48, month: 7)
        XCTAssertEqual(storm.precipitation, .rain)
        XCTAssertTrue(storm.thunder)

        let hail = SceneBuilder.scene(for: conditions(code: 99), latitude: 48, month: 7)
        XCTAssertEqual(hail.precipitation, .hail)
        XCTAssertTrue(hail.thunder)
        XCTAssertEqual(hail.intensity, 1)

        let fog = SceneBuilder.scene(for: conditions(code: 48), latitude: 48, month: 7)
        XCTAssertEqual(fog.precipitation, .none)
        XCTAssertEqual(fog.fog, 0.8)
        XCTAssertEqual(fog.intensity, 0)

        let snow = SceneBuilder.scene(for: conditions(code: 73, temp: -2), latitude: 48, month: 1)
        XCTAssertEqual(snow.precipitation, .snow)
        XCTAssertFalse(snow.melts)

        let freezing = SceneBuilder.scene(for: conditions(code: 67, temp: -1), latitude: 48, month: 1)
        XCTAssertEqual(freezing.precipitation, .rain)
        XCTAssertTrue(freezing.freezing)

        let clear = SceneBuilder.scene(for: conditions(code: 0, day: false), latitude: 48, month: 7)
        XCTAssertTrue(clear.isCalm)
        XCTAssertTrue(clear.isNight)
        XCTAssertTrue(clear.melts)
    }

    func testWindDriftFollowsTheCompass() {
        // A west wind blows toward the east, which is to the right.
        XCTAssertGreaterThan(SceneBuilder.scene(for: conditions(code: 61, wind: 20, from: 270), latitude: 0, month: 1).drift, 40)
        XCTAssertLessThan(SceneBuilder.scene(for: conditions(code: 61, wind: 20, from: 90), latitude: 0, month: 1).drift, -40)
        XCTAssertEqual(SceneBuilder.scene(for: conditions(code: 61, wind: 20, from: 0), latitude: 0, month: 1).drift, 0, accuracy: 0.001)
        let gale = SceneBuilder.scene(for: conditions(code: 61, wind: 200, from: 270), latitude: 0, month: 1)
        XCTAssertEqual(gale.drift, SceneBuilder.maxDrift)
    }

    func testLeavesOnlyBlowOnWindyCalmDays() {
        XCTAssertTrue(SceneBuilder.scene(for: conditions(code: 2, wind: 30), latitude: 48, month: 10).leaves)
        XCTAssertFalse(SceneBuilder.scene(for: conditions(code: 2, wind: 10), latitude: 48, month: 10).leaves)
        XCTAssertFalse(SceneBuilder.scene(for: conditions(code: 65, wind: 40), latitude: 48, month: 10).leaves, "too busy in a downpour")
        XCTAssertFalse(SceneBuilder.scene(for: conditions(code: 75, wind: 40), latitude: 48, month: 10).leaves, "no leaves in snow")
        XCTAssertFalse(SceneBuilder.scene(for: conditions(code: 48, wind: 40), latitude: 48, month: 10).leaves, "no leaves in thick fog")
    }

    func testLeafPaletteFollowsSeasonAndHemisphere() {
        XCTAssertEqual(LeafPalette.palette(latitude: 21.0, month: 10), .tropical, "Hanoi")
        XCTAssertEqual(LeafPalette.palette(latitude: 48.9, month: 10), .autumn, "Paris")
        XCTAssertEqual(LeafPalette.palette(latitude: 48.9, month: 12), .winter)
        XCTAssertEqual(LeafPalette.palette(latitude: 48.9, month: 4), .spring)
        XCTAssertEqual(LeafPalette.palette(latitude: -33.9, month: 10), .spring, "Sydney")
        XCTAssertEqual(LeafPalette.palette(latitude: -33.9, month: 4), .autumn)
        XCTAssertEqual(LeafPalette.palette(latitude: -33.9, month: 7), .winter)
    }

    func testPreviewsAllDrawSomething() {
        for p in WeatherPreview.allCases {
            let s = p.scene(palette: .autumn, isNight: false)
            XCTAssertFalse(s.isCalm, "\(p)")
            XCTAssertFalse(p.title.isEmpty)
        }
        XCTAssertFalse(WeatherPreview.snow.scene(palette: .autumn, isNight: false).melts, "preview snow must not melt while it falls")
    }

    func testTemperatureFormatting() {
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: 26.2), "26°")
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: -0.4), "0°")
        XCTAssertEqual(TemperatureUnit.celsius.format(celsius: -2.5), "-3°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(celsius: 26.2), "79°")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(celsius: -40), "-40°")
        XCTAssertEqual(TemperatureUnit.preferred(for: Locale(identifier: "en_US")), .fahrenheit)
        XCTAssertEqual(TemperatureUnit.preferred(for: Locale(identifier: "vi_VN")), .celsius)
        XCTAssertEqual(TemperatureUnit.preferred(for: Locale(identifier: "en_GB")), .celsius)
    }
}
