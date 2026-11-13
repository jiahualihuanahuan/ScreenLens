import Foundation

/// Decides how much of a window's top (title bar / tab bar / toolbar / URL bar / bookmarks bar)
/// must be skipped so that only the main content is translated.
///
/// Preferred path (handled in the app target): the Accessibility tree exposes the web content
/// (`AXWebArea`) or a document `AXScrollArea`, and that rect is used as-is.
/// These helpers cover the fallbacks:
///   1. Accessibility works but no web/scroll area was found: use the real bottoms of the window's
///      `AXToolbar` / tab-strip elements (`insetFromChromeBottoms`).
///   2. Nothing is known about the window: use a conservative heuristic (`fallbackTopInset`).
public enum ContentChrome {
    /// Typical macOS title bar height in points (traffic-light row without a toolbar).
    public static let standardTitleBar: CGFloat = 28
    /// Title bar + unified toolbar, used only when nothing better is known.
    public static let blindNonBrowserInset: CGFloat = 52
    /// Tab strip + address bar + bookmarks bar for a typical Chromium/Safari window.
    public static let blindBrowserInset: CGFloat = 114
    /// Never trim more than this fraction of the window height.
    public static let maxTrimFraction: CGFloat = 0.24

    /// Largest chrome bottom (quartz y) that plausibly belongs to top chrome, expressed as an inset
    /// from the window's top edge. Only bottoms inside the upper 35% of the window are believed.
    /// Returns nil when no candidate qualifies.
    public static func insetFromChromeBottoms(windowRect: CGRect, chromeBottoms: [CGFloat]) -> CGFloat? {
        guard windowRect.height > 0 else { return nil }
        let limit = windowRect.height * 0.35
        var best: CGFloat?
        for bottom in chromeBottoms {
            let inset = bottom - windowRect.minY
            guard inset > 0, inset <= limit else { continue }
            best = max(best ?? 0, inset)
        }
        return best
    }

    /// Heuristic top inset when the Accessibility tree gave no usable content or toolbar rect.
    /// - Parameters:
    ///   - isFullScreen: macOS full-screen windows have no title bar; browsers auto-hide the toolbar.
    ///   - accessibilityKnown: true when AX could read the window (so the title bar is known to exist
    ///     and only the toolbar is unknown).
    public static func fallbackTopInset(windowRect: CGRect,
                                        isBrowser: Bool,
                                        isArc: Bool,
                                        isFullScreen: Bool,
                                        accessibilityKnown: Bool) -> CGFloat {
        var inset: CGFloat
        if isFullScreen {
            inset = 0
        } else if isArc {
            inset = 24
        } else if isBrowser {
            inset = blindBrowserInset
        } else {
            inset = accessibilityKnown ? standardTitleBar : blindNonBrowserInset
        }
        inset = min(inset, windowRect.height * maxTrimFraction)
        return max(inset, 0)
    }

    /// Left inset for Arc's sidebar. Scaled to the window instead of a fixed 215pt.
    public static func fallbackLeftInset(windowRect: CGRect, isArc: Bool, isFullScreen: Bool) -> CGFloat {
        guard isArc, windowRect.width > 920 else { return 0 }
        return min(215, windowRect.width * 0.22)
    }

    /// Applies insets to a window rect, never collapsing below a minimal usable size.
    public static func contentRect(window: CGRect, topInset: CGFloat, leftInset: CGFloat) -> CGRect {
        let top = min(max(topInset, 0), max(window.height - 80, 0))
        let left = min(max(leftInset, 0), max(window.width - 100, 0))
        return CGRect(x: window.origin.x + left,
                      y: window.origin.y + top,
                      width: window.width - left,
                      height: window.height - top)
    }
}

/// Size-independent (point based) text-block filters used for "translate main content".
/// The old code used fractions of the capture size, which meant the same sidebar label was kept on a
/// 13" MacBook and dropped on a 32" display (or vice versa).
public enum ContentFilter {
    /// `normalizedBox` is Vision-normalized (0...1, bottom-left) inside a region of `regionSize` points.
    /// True for scrollbar / window-border artifacts hugging the left or right edge.
    public static func isWindowBorderArtifact(normalizedBox box: CGRect, regionSize: CGSize) -> Bool {
        let leftGap = box.minX * regionSize.width
        let rightGap = (1 - box.maxX) * regionSize.width
        return leftGap < 6 || rightGap < 6
    }

    /// True for short single-line labels that sit in a narrow rail at the far left/right edge
    /// (icon rails, sidebars, badges). Thresholds are in points.
    public static func isEdgeRailLabel(normalizedBox box: CGRect, regionSize: CGSize) -> Bool {
        let w = box.width * regionSize.width
        let h = box.height * regionSize.height
        guard h < 36, w < 150 else { return false }
        let leftGap = box.minX * regionSize.width
        let rightGap = (1 - box.maxX) * regionSize.width
        return leftGap + w < 170 || rightGap + w < 170
    }

    /// Distance in points from the top edge of the region to the top of the box.
    public static func distanceFromTop(normalizedBox box: CGRect, regionSize: CGSize) -> CGFloat {
        (1 - box.maxY) * regionSize.height
    }

    /// True for short single-line text in the top strip typical for browser tab titles / bookmarks.
    public static func isTopStripLabel(normalizedBox box: CGRect, regionSize: CGSize) -> Bool {
        distanceFromTop(normalizedBox: box, regionSize: regionSize) < 88
            && box.width * regionSize.width < 320
            && box.height * regionSize.height < 36
    }
}
