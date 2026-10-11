import AppKit
import WeatherglassCore

/// Reads where every window is. Needs no permission: only positions and levels are read, never titles or pixels.
@MainActor
enum WindowTracker {
    /// Front-to-back list of on-screen windows, in Cocoa global coordinates.
    static func onscreen() -> [OnscreenWindow] {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let height = primary.frame.height
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return OnscreenWindow(id: id, frame: Geometry.cocoaRect(fromCG: bounds, primaryHeight: height),
                                  layer: layer, alpha: alpha)
        }
    }
}
