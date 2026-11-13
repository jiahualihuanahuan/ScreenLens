import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import ScreenLensCore

final class ContentChromeTests: XCTestCase {
    private let window = CGRect(x: 100, y: 40, width: 1200, height: 800)

    func testToolbarBottomsUseRealMeasurement() {
        // Tab strip bottom at y=80, address bar bottom at y=124, bookmarks bar bottom at y=156.
        let inset = ContentChrome.insetFromChromeBottoms(windowRect: window, chromeBottoms: [80, 124, 156])
        XCTAssertEqual(inset, 116)
    }

    func testImplausibleBottomsAreIgnored() {
        // 500pt below the top is content, not chrome. Bottom above the window is nonsense.
        XCTAssertNil(ContentChrome.insetFromChromeBottoms(windowRect: window, chromeBottoms: [540, 10]))
    }

    func testFallbackBrowserVsNative() {
        XCTAssertEqual(ContentChrome.fallbackTopInset(windowRect: window, isBrowser: true, isArc: false,
                                                      isFullScreen: false, accessibilityKnown: false), 114)
        XCTAssertEqual(ContentChrome.fallbackTopInset(windowRect: window, isBrowser: false, isArc: false,
                                                      isFullScreen: false, accessibilityKnown: true), 28)
        XCTAssertEqual(ContentChrome.fallbackTopInset(windowRect: window, isBrowser: false, isArc: false,
                                                      isFullScreen: false, accessibilityKnown: false), 52)
    }

    func testFullScreenHasNoTitleBarInset() {
        XCTAssertEqual(ContentChrome.fallbackTopInset(windowRect: window, isBrowser: true, isArc: false,
                                                      isFullScreen: true, accessibilityKnown: false), 0)
    }

    func testFallbackNeverTrimsMoreThanQuarterOfSmallWindow() {
        let small = CGRect(x: 0, y: 0, width: 600, height: 300)
        XCTAssertEqual(ContentChrome.fallbackTopInset(windowRect: small, isBrowser: true, isArc: false,
                                                      isFullScreen: false, accessibilityKnown: false), 72, accuracy: 0.001)
    }

    func testArcSidebarScalesWithWindow() {
        let narrow = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertEqual(ContentChrome.fallbackLeftInset(windowRect: narrow, isArc: true, isFullScreen: false), 215)
        let wide = CGRect(x: 0, y: 0, width: 3000, height: 1200)
        XCTAssertEqual(ContentChrome.fallbackLeftInset(windowRect: wide, isArc: true, isFullScreen: false), 215)
        XCTAssertEqual(ContentChrome.fallbackLeftInset(windowRect: narrow, isArc: false, isFullScreen: false), 0)
    }

    func testContentRectAppliesInsetsAndKeepsMinimumSize() {
        let r = ContentChrome.contentRect(window: window, topInset: 100, leftInset: 0)
        XCTAssertEqual(r, CGRect(x: 100, y: 140, width: 1200, height: 700))
        let tiny = ContentChrome.contentRect(window: CGRect(x: 0, y: 0, width: 150, height: 100),
                                             topInset: 500, leftInset: 500)
        XCTAssertGreaterThan(tiny.width, 0)
        XCTAssertGreaterThan(tiny.height, 0)
    }

    func testBorderAndRailFiltersAreSizeIndependent() {
        // A 90pt-wide label 20pt from the left edge is a sidebar label in any window size.
        for size in [CGSize(width: 800, height: 600), CGSize(width: 3000, height: 1600)] {
            let box = CGRect(x: 20 / size.width, y: 0.5, width: 90 / size.width, height: 14 / size.height)
            XCTAssertTrue(ContentFilter.isEdgeRailLabel(normalizedBox: box, regionSize: size))
        }
        // The same label centred in a wide window is content.
        let size = CGSize(width: 3000, height: 1600)
        let centred = CGRect(x: 1400 / size.width, y: 0.5, width: 90 / size.width, height: 14 / size.height)
        XCTAssertFalse(ContentFilter.isEdgeRailLabel(normalizedBox: centred, regionSize: size))
        // Text 300pt from the edge in a 3000pt window was dropped by the old 16% rule; now kept.
        let old = CGRect(x: 300 / size.width, y: 0.5, width: 90 / size.width, height: 14 / size.height)
        XCTAssertFalse(ContentFilter.isEdgeRailLabel(normalizedBox: old, regionSize: size))
        // Border artifacts
        XCTAssertTrue(ContentFilter.isWindowBorderArtifact(
            normalizedBox: CGRect(x: 0.001, y: 0.5, width: 0.05, height: 0.01), regionSize: size))
        XCTAssertFalse(ContentFilter.isWindowBorderArtifact(
            normalizedBox: CGRect(x: 0.05, y: 0.5, width: 0.05, height: 0.01), regionSize: size))
    }

    func testTopStripLabel() {
        let size = CGSize(width: 1200, height: 800)
        let tab = CGRect(x: 0.2, y: 1 - 30.0 / 800 - 14.0 / 800, width: 150.0 / 1200, height: 14.0 / 800)
        XCTAssertTrue(ContentFilter.isTopStripLabel(normalizedBox: tab, regionSize: size))
        let heading = CGRect(x: 0.2, y: 1 - 300.0 / 800 - 14.0 / 800, width: 150.0 / 1200, height: 14.0 / 800)
        XCTAssertFalse(ContentFilter.isTopStripLabel(normalizedBox: heading, regionSize: size))
    }
}
