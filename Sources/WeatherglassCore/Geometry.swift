import CoreGraphics

/// One window from the window server, in front-to-back order.
public struct OnscreenWindow: Equatable, Sendable {
    public var id: UInt32
    /// Cocoa global coordinates: origin at the bottom left of the primary display, y up.
    public var frame: CGRect
    /// The window level. Normal app windows are 0.
    public var layer: Int
    public var alpha: Double

    public init(id: UInt32, frame: CGRect, layer: Int, alpha: Double) {
        self.id = id
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
    }
}

/// A window whose top edge can hold snow, and the parts of that edge nothing covers.
public struct SnowHost: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    /// Uncovered spans of the top edge, in global x.
    public var visible: [ClosedRange<CGFloat>]

    public init(id: UInt32, frame: CGRect, visible: [ClosedRange<CGFloat>]) {
        self.id = id
        self.frame = frame
        self.visible = visible
    }
}

public enum Geometry {
    /// Window server rects have their origin at the top left of the primary display, with y down.
    public static func cocoaRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The spans of [minX, maxX] that no occluder covers inside the band [y - below, y + above].
    public static func uncovered(minX: CGFloat, maxX: CGFloat, y: CGFloat, above: CGFloat, below: CGFloat,
                                 occluders: [CGRect], minSpan: CGFloat) -> [ClosedRange<CGFloat>] {
        guard maxX > minX else { return [] }
        var spans: [ClosedRange<CGFloat>] = [minX...maxX]
        for o in occluders where o.minY < y + above && o.maxY > y - below {
            var next: [ClosedRange<CGFloat>] = []
            for s in spans {
                if o.maxX <= s.lowerBound || o.minX >= s.upperBound {
                    next.append(s)
                    continue
                }
                if o.minX > s.lowerBound { next.append(s.lowerBound...o.minX) }
                if o.maxX < s.upperBound { next.append(o.maxX...s.upperBound) }
            }
            spans = next
            if spans.isEmpty { break }
        }
        return spans.filter { $0.upperBound - $0.lowerBound >= minSpan }
    }

    /// Picks the windows that can hold snow and works out which parts of their top edges show.
    ///
    /// - Parameters:
    ///   - windows: every on-screen window, front to back.
    ///   - overlayLevel: windows above this level are drawn over the snow anyway, so they do not occlude it.
    ///   - excluded: our own overlay windows. They neither hold snow nor hide it.
    ///   - nonHosts: windows that hide what is behind them but never hold snow (the demo backdrop).
    ///   - capHeight: how far snow can rise above an edge.
    public static func snowHosts(windows: [OnscreenWindow], overlayLevel: Int, excluded: Set<UInt32>,
                                 nonHosts: Set<UInt32> = [], capHeight: CGFloat, minWidth: CGFloat = 120,
                                 minHeight: CGFloat = 60, minSpan: CGFloat = 24) -> [SnowHost] {
        var hosts: [SnowHost] = []
        var inFront: [CGRect] = []
        for w in windows where !excluded.contains(w.id) {
            guard w.layer >= 0, w.layer <= overlayLevel, w.alpha > 0.1 else { continue }
            if w.layer == 0, w.alpha > 0.3, !nonHosts.contains(w.id),
               w.frame.width >= minWidth, w.frame.height >= minHeight {
                let visible = uncovered(minX: w.frame.minX, maxX: w.frame.maxX, y: w.frame.maxY,
                                        above: capHeight, below: 2, occluders: inFront, minSpan: minSpan)
                if !visible.isEmpty {
                    hosts.append(SnowHost(id: w.id, frame: w.frame, visible: visible))
                }
            }
            inFront.append(w.frame)
        }
        return hosts
    }
}
