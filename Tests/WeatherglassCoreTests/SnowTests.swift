import CoreGraphics
import XCTest
@testable import WeatherglassCore

final class GeometryTests: XCTestCase {
    func testConvertsWindowServerRects() {
        // A 400×300 window 100 pt from the top of a 1000 pt tall display.
        let r = Geometry.cocoaRect(fromCG: CGRect(x: 50, y: 100, width: 400, height: 300), primaryHeight: 1000)
        XCTAssertEqual(r, CGRect(x: 50, y: 600, width: 400, height: 300))
    }

    func testUncoveredSpans() {
        let full = Geometry.uncovered(minX: 0, maxX: 500, y: 700, above: 20, below: 2, occluders: [], minSpan: 10)
        XCTAssertEqual(full, [0...500])

        // A window covering the middle of the edge splits it in two.
        let split = Geometry.uncovered(minX: 0, maxX: 500, y: 700, above: 20, below: 2,
                                       occluders: [CGRect(x: 200, y: 650, width: 100, height: 100)], minSpan: 10)
        XCTAssertEqual(split, [0...200, 300...500])

        // A window far below the edge does not cover it.
        let below = Geometry.uncovered(minX: 0, maxX: 500, y: 700, above: 20, below: 2,
                                       occluders: [CGRect(x: 0, y: 100, width: 500, height: 100)], minSpan: 10)
        XCTAssertEqual(below, [0...500])

        // A window just above the edge covers the snow that would sit there.
        let above = Geometry.uncovered(minX: 0, maxX: 500, y: 700, above: 20, below: 2,
                                       occluders: [CGRect(x: 0, y: 710, width: 495, height: 100)], minSpan: 10)
        XCTAssertEqual(above, [], "a 5 pt sliver is too small to keep")
    }

    func testSnowHosts() {
        let overlay: UInt32 = 99
        let windows = [
            OnscreenWindow(id: overlay, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 3, alpha: 1),
            OnscreenWindow(id: 1, frame: CGRect(x: 100, y: 300, width: 600, height: 400), layer: 0, alpha: 1),
            OnscreenWindow(id: 2, frame: CGRect(x: 400, y: 200, width: 600, height: 480), layer: 0, alpha: 1),
            OnscreenWindow(id: 3, frame: CGRect(x: 0, y: 0, width: 80, height: 80), layer: 0, alpha: 1),
            OnscreenWindow(id: 4, frame: CGRect(x: 0, y: 860, width: 1440, height: 40), layer: 25, alpha: 1),
        ]
        let hosts = Geometry.snowHosts(windows: windows, overlayLevel: 3, excluded: [overlay], capHeight: 20)
        XCTAssertEqual(hosts.map(\.id), [1, 2], "the overlay, the tiny window and the menu bar hold no snow")
        XCTAssertEqual(hosts[0].visible, [100...700])
        // Window 1 sits in front and covers x 400...700 just above window 2's top edge (y 680).
        XCTAssertEqual(hosts[1].visible, [700...1000])
    }

    func testBackdropHidesWindowsBehindItButHoldsNoSnow() {
        let windows = [
            OnscreenWindow(id: 1, frame: CGRect(x: 100, y: 300, width: 600, height: 400), layer: 0, alpha: 1),
            OnscreenWindow(id: 50, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 0, alpha: 1),
            OnscreenWindow(id: 2, frame: CGRect(x: 400, y: 200, width: 600, height: 300), layer: 0, alpha: 1),
        ]
        let hosts = Geometry.snowHosts(windows: windows, overlayLevel: 3, excluded: [], nonHosts: [50], capHeight: 20)
        XCTAssertEqual(hosts.map(\.id), [1])
    }
}

final class SnowCapTests: XCTestCase {
    func testGrowsOnlyWhereVisibleAndNeverPastTheLimit() {
        var cap = SnowCap(width: 300, seed: 7)
        XCTAssertTrue(cap.isEmpty)
        for _ in 0..<600 {
            cap.accumulate(seconds: 0.5, rate: 0.2, maxHeight: 14, visible: [0...150])
        }
        XCTAssertFalse(cap.isEmpty)
        XCTAssertLessThanOrEqual(cap.peak, 14 + 1e-9)
        // Columns well inside the hidden half stay bare, except where snow slid over the boundary.
        let hidden = cap.heights[(200 / 3)...]
        XCTAssertEqual(hidden.max() ?? 0, 0, accuracy: 0.001)
        XCTAssertGreaterThan(cap.heights[25], 10)
    }

    func testRoundEndsAndGentleSlopes() {
        var cap = SnowCap(width: 400, seed: 3)
        for _ in 0..<1000 {
            cap.accumulate(seconds: 0.5, rate: 0.3, maxHeight: 16, visible: [0...400])
        }
        let h = cap.heights
        XCTAssertLessThan(h.first!, h[h.count / 2] / 2, "left end is rounded")
        XCTAssertLessThan(h.last!, h[h.count / 2] / 2, "right end is rounded")
        // Away from the round ends, no slope is steeper than snow can hold.
        let ends = Int(SnowCap.taper / SnowCap.bin) + 1
        for i in ends..<(h.count - 1 - ends) {
            XCTAssertLessThanOrEqual(abs(h[i] - h[i + 1]), SnowCap.maxStep + 1e-9, "column \(i)")
        }
        XCTAssertGreaterThan(h.max()! - h[h.count / 4...h.count * 3 / 4].min()!, 0.5, "the top is bumpy, not flat")
    }

    func testMeltsAway() {
        var cap = SnowCap(width: 200, seed: 1)
        for _ in 0..<200 { cap.accumulate(seconds: 1, rate: 0.2, maxHeight: 12, visible: [0...200]) }
        let before = cap.peak
        cap.melt(seconds: 10, rate: 0.2)
        XCTAssertLessThan(cap.peak, before)
        cap.melt(seconds: 1000, rate: 0.2)
        XCTAssertTrue(cap.isEmpty)
    }

    func testSameSeedSameShape() {
        var a = SnowCap(width: 250, seed: 42)
        var b = SnowCap(width: 250, seed: 42)
        for _ in 0..<50 {
            a.accumulate(seconds: 1, rate: 0.3, maxHeight: 12, visible: [0...250])
            b.accumulate(seconds: 1, rate: 0.3, maxHeight: 12, visible: [0...250])
        }
        XCTAssertEqual(a, b)
    }

    func testTinyWidths() {
        var cap = SnowCap(width: 0, seed: 1)
        cap.accumulate(seconds: 10, rate: 1, maxHeight: 10, visible: [0...0])
        XCTAssertEqual(cap.heights.count, 1)
        XCTAssertLessThanOrEqual(cap.peak, 10)
    }
}

final class SnowFieldTests: XCTestCase {
    let a = SnowHost(id: 1, frame: CGRect(x: 100, y: 300, width: 600, height: 400), visible: [100...700])

    func snowy(_ field: SnowField, _ hosts: [SnowHost], from t: TimeInterval, seconds: Int) -> [SnowField.Fall] {
        var falls: [SnowField.Fall] = []
        for i in 0..<seconds {
            falls += field.update(hosts: hosts, now: t + Double(i), dt: 1, snowRate: 0.2, maxHeight: 14, meltRate: 0)
        }
        return falls
    }

    func testSnowFallsOffAMovedWindow() {
        let field = SnowField()
        XCTAssertEqual(snowy(field, [a], from: 0, seconds: 60), [])
        XCTAssertEqual(field.caps.count, 1)

        var moved = a
        moved.frame.origin.x += 40
        moved.visible = [140...740]
        let falls = field.update(hosts: [moved], now: 60, dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0)
        XCTAssertEqual(falls.count, 1)
        XCTAssertEqual(falls[0].frame, a.frame, "snow falls from where the window was")
        XCTAssertTrue(field.caps.isEmpty, "the window starts bare in its new place")
    }

    func testResizingFromTheBottomKeepsTheSnow() {
        let field = SnowField()
        _ = snowy(field, [a], from: 0, seconds: 30)
        var taller = a
        taller.frame = CGRect(x: 100, y: 200, width: 600, height: 500) // same top edge, y + height = 700
        XCTAssertEqual(field.update(hosts: [taller], now: 30, dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0), [])
        XCTAssertEqual(field.caps.count, 1)
    }

    func testClosedWindowDropsItsSnow() {
        let field = SnowField()
        _ = snowy(field, [a], from: 0, seconds: 30)
        let falls = field.update(hosts: [], now: 30, dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0)
        XCTAssertEqual(falls.map(\.windowID), [1])
        XCTAssertTrue(field.caps.isEmpty)
    }

    func testSpaceChangeKeepsSnowForLater() {
        let field = SnowField()
        _ = snowy(field, [a], from: 0, seconds: 30)
        field.spaceChangedAt = 30
        XCTAssertEqual(field.update(hosts: [], now: 30.5, dt: 0.5, snowRate: 0.2, maxHeight: 14, meltRate: 0), [],
                       "windows left on the other Space do not shed snow")
        XCTAssertTrue(field.caps.isEmpty, "and are not drawn here")
        // Coming back: the same window, same place, still has its snow.
        _ = field.update(hosts: [a], now: 40, dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0)
        XCTAssertEqual(field.caps.count, 1)
        // Gone for longer than the limit: forgotten without a fall.
        field.spaceChangedAt = 50
        _ = field.update(hosts: [], now: 50.1, dt: 0.1, snowRate: 0, maxHeight: 14, meltRate: 0)
        XCTAssertEqual(field.update(hosts: [], now: 50 + SnowField.parkLimit + 1, dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0), [])
        _ = field.update(hosts: [a], now: 50 + SnowField.parkLimit + 2, dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0)
        XCTAssertTrue(field.caps.isEmpty)
    }

    func testMeltingAndShakingOff() {
        let field = SnowField()
        _ = snowy(field, [a], from: 0, seconds: 30)
        for i in 0..<400 {
            _ = field.update(hosts: [a], now: 30 + Double(i), dt: 1, snowRate: 0, maxHeight: 14, meltRate: 0.1)
        }
        XCTAssertTrue(field.caps.isEmpty, "melted")

        _ = snowy(field, [a], from: 500, seconds: 30)
        XCTAssertEqual(field.shakeOff().count, 1)
        XCTAssertTrue(field.isEmpty)
    }

    func testNarrowWindowsHoldLessSnow() {
        XCTAssertEqual(SnowField.maxHeight(width: 1000, base: 14), 14)
        XCTAssertEqual(SnowField.maxHeight(width: 100, base: 14), 6, accuracy: 1e-9)
        XCTAssertEqual(SnowField.maxHeight(width: 20, base: 14), 4)
    }
}
