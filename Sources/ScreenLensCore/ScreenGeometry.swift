import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure geometry helpers shared by the app target. They deliberately depend on
/// Foundation only (no AppKit / ScreenCaptureKit) so they can be unit-tested on any platform.
///
/// Coordinate conventions used throughout ScreenLens:
///  * "Quartz" space: global display space, origin at the TOP-LEFT of the primary display,
///    y grows downward, units are points. Used by Accessibility, CGWindowList and ScreenCaptureKit.
///  * "AppKit" space: origin at the BOTTOM-LEFT of the primary display, y grows upward, units are points.
///    Used by NSScreen / NSWindow.
///  * "Vision normalized": 0...1 relative to the OCR'd image, origin at the BOTTOM-LEFT.
public enum ScreenGeometry {
    /// Quartz (top-left) -> AppKit (bottom-left). `primaryHeight` is the height in points of the
    /// display that owns the global origin (the one whose NSScreen frame origin is (0,0)).
    public static func quartzToAppKit(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    /// AppKit (bottom-left) -> Quartz (top-left).
    public static func appKitToQuartz(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// Index of the frame that overlaps `rect` the most (by area). Returns nil when nothing overlaps.
    /// Works in whichever single coordinate space both arguments share.
    public static func bestMatchIndex(for rect: CGRect, in frames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (i, frame) in frames.enumerated() {
            let inter = frame.intersection(rect)
            if inter.isNull || inter.isEmpty { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// Pixel dimensions needed to capture `pointSize` at `pointPixelScale` pixels per point.
    /// Rounds to the nearest pixel and never returns less than 1.
    public static func pixelSize(forPointSize pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let s = scale > 0 ? scale : 1
        return (max(1, Int((pointSize.width * s).rounded())),
                max(1, Int((pointSize.height * s).rounded())))
    }
}
