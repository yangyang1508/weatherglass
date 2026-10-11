import CoreGraphics
import Foundation

/// A small, seedable random generator, so snow shapes are the same in every test run.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Snow lying on one top edge, stored as a height for every few points of width.
public struct SnowCap: Equatable, Sendable {
    /// Width of one column, in points.
    public static let bin: Double = 3
    /// Snow thins out over this many points at each end, so a cap has round ends.
    public static let taper: Double = 16
    /// The steepest step between columns. Snow slides off anything steeper (about 40°).
    public static let maxStep: Double = bin * 0.85

    public let width: Double
    public private(set) var heights: [Double]
    /// How fast each column fills, around 1.
    private let growth: [Double]
    /// How full each column may get, 0.72...1. Keeps a full cap soft and bumpy instead of flat.
    private let shape: [Double]

    public init(width: Double, seed: UInt64) {
        self.width = max(width, 0)
        let n = max(Int((self.width / Self.bin).rounded(.up)), 1)
        heights = Array(repeating: 0, count: n)
        // Gentle bumps: a few slow waves with random phases, so it looks like soft pillows of snow.
        var rng = SplitMix64(seed: seed)
        let waves = (0..<3).map { _ in
            (length: Double.random(in: 40...160, using: &rng),
             phase: Double.random(in: 0...(2 * .pi), using: &rng),
             weight: Double.random(in: 0.5...1, using: &rng))
        }
        let total = waves.reduce(0) { $0 + $1.weight }
        let wave = (0..<n).map { i -> Double in
            let x = (Double(i) + 0.5) * Self.bin
            return waves.reduce(0) { $0 + $1.weight * sin(x / $1.length * 2 * .pi + $1.phase) } / total
        }
        growth = wave.map { 0.8 + 0.3 * $0 }
        shape = wave.map { 0.8 + 0.2 * $0 }
    }

    public var isEmpty: Bool { heights.allSatisfy { $0 < 0.05 } }
    public var peak: Double { heights.max() ?? 0 }

    /// How tall snow may get at column `i`: full height in the middle, rounding off at the ends.
    func envelope(_ i: Int) -> Double {
        let x = (Double(i) + 0.5) * Self.bin
        let edge = min(x, width - x)
        return min(1, sqrt(max(edge, 0) / Self.taper))
    }

    func limit(_ i: Int, maxHeight: Double) -> Double {
        maxHeight * envelope(i) * shape[i]
    }

    /// Adds snow to the columns inside `visible` (x measured from the left end of the edge).
    public mutating func accumulate(seconds: Double, rate: Double, maxHeight: Double, visible: [ClosedRange<Double>]) {
        guard seconds > 0, rate > 0, maxHeight > 0 else { return }
        for i in heights.indices {
            let x = (Double(i) + 0.5) * Self.bin
            guard visible.contains(where: { $0.contains(x) }) else { continue }
            heights[i] = min(heights[i] + rate * seconds * growth[i], limit(i, maxHeight: maxHeight))
        }
        settle(maxHeight: maxHeight)
    }

    /// Removes snow evenly. Thin snow goes first, so the cap shrinks toward its middle.
    public mutating func melt(seconds: Double, rate: Double) {
        guard seconds > 0, rate > 0 else { return }
        for i in heights.indices {
            heights[i] = max(heights[i] - rate * seconds * (1.2 - envelope(i) * 0.4), 0)
        }
    }

    /// Snow slides off slopes steeper than `maxStep`.
    mutating func settle(maxHeight: Double) {
        guard heights.count > 1 else { return }
        for _ in 0..<2 {
            for i in 0..<(heights.count - 1) {
                let d = heights[i] - heights[i + 1]
                if abs(d) > Self.maxStep {
                    let move = (abs(d) - Self.maxStep) / 2
                    if d > 0 { heights[i] -= move; heights[i + 1] += move } else { heights[i] += move; heights[i + 1] -= move }
                }
            }
        }
        // Moving snow sideways can push a column past its limit near the ends; trim it.
        for i in heights.indices {
            heights[i] = min(heights[i], limit(i, maxHeight: maxHeight))
        }
    }
}

/// All the snow on all the windows. Knows when a window moved, so its snow falls off.
public final class SnowField {
    /// Snow that just fell off a window that moved, closed or hid.
    public struct Fall: Equatable, Sendable {
        public let windowID: UInt32
        /// Where the window was, in Cocoa global coordinates.
        public let frame: CGRect
        public let heights: [Double]
    }

    public struct Cap: Equatable, Sendable {
        public let windowID: UInt32
        public let frame: CGRect
        public let heights: [Double]
        public let visible: [ClosedRange<CGFloat>]
    }

    struct Entry {
        var frame: CGRect
        var cap: SnowCap
        var visible: [ClosedRange<CGFloat>]
        var lastSeen: TimeInterval
        var parked: Bool
    }

    /// Windows that vanish this soon after a Space change were left behind on the old Space; keep their snow.
    public static let spaceGrace: TimeInterval = 1.5
    /// Forget snow on windows we have not seen for this long.
    public static let parkLimit: TimeInterval = 30 * 60

    private(set) var entries: [UInt32: Entry] = [:]
    public var spaceChangedAt: TimeInterval = -.infinity

    public init() {}

    public var isEmpty: Bool { entries.values.allSatisfy { $0.cap.isEmpty } }

    /// The tallest a cap can get on a window this wide.
    public static func maxHeight(width: CGFloat, base: Double) -> Double {
        min(base, max(4, Double(width) * 0.06))
    }

    static func sameTopEdge(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.maxY - b.maxY) < 0.5 && abs(a.width - b.width) < 0.5
    }

    /// Advances the snow by `dt` seconds.
    ///
    /// - Parameters:
    ///   - snowRate: points per second of new snow (0 when it is not snowing).
    ///   - maxHeight: the tallest a cap may get.
    ///   - meltRate: points per second of melting (0 when it is cold).
    /// - Returns: the snow that fell off windows that moved or went away.
    @discardableResult
    public func update(hosts: [SnowHost], now: TimeInterval, dt: Double, snowRate: Double,
                       maxHeight: Double, meltRate: Double) -> [Fall] {
        var falls: [Fall] = []
        var seen = Set<UInt32>()
        for h in hosts {
            seen.insert(h.id)
            if var e = entries[h.id] {
                if !Self.sameTopEdge(e.frame, h.frame) {
                    if !e.parked && !e.cap.isEmpty {
                        falls.append(Fall(windowID: h.id, frame: e.frame, heights: e.cap.heights))
                    }
                    e.cap = SnowCap(width: Double(h.frame.width), seed: UInt64(h.id))
                }
                e.frame = h.frame
                e.visible = h.visible
                e.lastSeen = now
                e.parked = false
                entries[h.id] = e
            } else {
                entries[h.id] = Entry(frame: h.frame, cap: SnowCap(width: Double(h.frame.width), seed: UInt64(h.id)),
                                      visible: h.visible, lastSeen: now, parked: false)
            }
            let e = entries[h.id]!
            let local = e.visible.map { Double($0.lowerBound - e.frame.minX)...Double($0.upperBound - e.frame.minX) }
            if snowRate > 0 {
                entries[h.id]!.cap.accumulate(seconds: dt, rate: snowRate,
                                              maxHeight: Self.maxHeight(width: e.frame.width, base: maxHeight),
                                              visible: local)
            }
            if meltRate > 0 {
                entries[h.id]!.cap.melt(seconds: dt, rate: meltRate)
            }
        }

        for (id, e) in entries where !seen.contains(id) {
            if e.parked {
                if now - e.lastSeen > Self.parkLimit { entries[id] = nil }
                continue
            }
            if now - spaceChangedAt < Self.spaceGrace {
                entries[id]!.parked = true
                continue
            }
            if !e.cap.isEmpty {
                falls.append(Fall(windowID: id, frame: e.frame, heights: e.cap.heights))
            }
            entries[id] = nil
        }
        return falls
    }

    /// The caps to draw: only windows on screen that have some snow.
    public var caps: [Cap] {
        entries.compactMap { id, e in
            guard !e.parked, !e.cap.isEmpty else { return nil }
            return Cap(windowID: id, frame: e.frame, heights: e.cap.heights, visible: e.visible)
        }
        .sorted { $0.windowID < $1.windowID }
    }

    /// Lets all snow fall at once, for example when the user turns snow off.
    public func shakeOff() -> [Fall] {
        let falls = entries.compactMap { id, e -> Fall? in
            guard !e.parked, !e.cap.isEmpty else { return nil }
            return Fall(windowID: id, frame: e.frame, heights: e.cap.heights)
        }
        entries.removeAll()
        return falls
    }

    public func removeAll() { entries.removeAll() }
}
