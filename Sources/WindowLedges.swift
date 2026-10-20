import AppKit
import CoreGraphics

struct DesktopWindow {
    let id: UInt32
    let frame: CGRect
}

enum WindowLedges {
    /// Quartz uses the upper-left of the primary display; AppKit uses its lower-left.
    static func appKitFrame(_ bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
               width: bounds.width, height: bounds.height)
    }

    @MainActor
    static func read() -> [DesktopWindow] {
        guard let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return [] }
        // Bounds, IDs and layers suffice. No window titles, screenshots or permission requests.
        return windows.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int, (0...3).contains(layer),
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.1,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= 80, height >= 60 else { return nil }
            return DesktopWindow(id: id, frame: appKitFrame(CGRect(x: x, y: y, width: width, height: height),
                                                            primaryHeight: primary.frame.maxY))
        }
    }

    /// Only exposed portions are platforms; foreground windows hide the rims behind them.
    static func make(from windows: [DesktopWindow], area: CGRect) -> [Ledge] {
        var frontFrames: [CGRect] = []
        var result: [Ledge] = []
        for window in windows {
            let frame = window.frame
            guard frame.intersects(area) else { continue }
            for (edge, y, suffix) in [(LedgeEdge.upper, frame.maxY, UInt64(0)),
                                      (LedgeEdge.lower, frame.minY, UInt64(1))] {
                guard y > area.minY + 1, y < area.maxY else { continue }
                var segments = [(max(area.minX, frame.minX), min(area.maxX, frame.maxX))]
                for front in frontFrames where y > front.minY - 1 && y < front.maxY + 1 {
                    segments = segments.flatMap { left, right -> [(CGFloat, CGFloat)] in
                        if front.maxX <= left || front.minX >= right { return [(left, right)] }
                        var pieces: [(CGFloat, CGFloat)] = []
                        if front.minX > left { pieces.append((left, min(right, front.minX))) }
                        if front.maxX < right { pieces.append((max(left, front.maxX), right)) }
                        return pieces
                    }
                }
                for (left, right) in segments where right - left > 12 {
                    result.append(Ledge(id: UInt64(window.id) * 2 + suffix, edge: edge,
                                        minX: left, maxX: right, y: y, carrierOrigin: frame.origin))
                }
            }
            frontFrames.append(frame)
        }
        return result
    }
}
