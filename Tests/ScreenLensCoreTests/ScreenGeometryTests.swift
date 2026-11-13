import XCTest
@testable import ScreenLensCore

final class ScreenGeometryTests: XCTestCase {
    func testQuartzAppKitRoundTripOnPrimary() {
        let r = CGRect(x: 100, y: 50, width: 400, height: 300)
        let appKit = ScreenGeometry.quartzToAppKit(r, primaryHeight: 900)
        XCTAssertEqual(appKit, CGRect(x: 100, y: 550, width: 400, height: 300))
        XCTAssertEqual(ScreenGeometry.appKitToQuartz(appKit, primaryHeight: 900), r)
    }

    /// External monitor ABOVE the primary display: AppKit y is > primary height,
    /// Quartz y is negative.
    func testDisplayAbovePrimaryUsesNegativeQuartzY() {
        let primaryHeight: CGFloat = 900
        let externalAppKit = CGRect(x: 0, y: 900, width: 2560, height: 1440)
        let quartz = ScreenGeometry.appKitToQuartz(externalAppKit, primaryHeight: primaryHeight)
        XCTAssertEqual(quartz.origin.y, -1440)
        XCTAssertEqual(ScreenGeometry.quartzToAppKit(quartz, primaryHeight: primaryHeight), externalAppKit)
    }

    func testDisplayLeftOfPrimary() {
        let r = CGRect(x: -1920, y: 100, width: 800, height: 600)
        let appKit = ScreenGeometry.quartzToAppKit(r, primaryHeight: 1117)
        XCTAssertEqual(appKit.origin.x, -1920)
        XCTAssertEqual(ScreenGeometry.appKitToQuartz(appKit, primaryHeight: 1117), r)
    }

    func testBestMatchPicksLargestOverlapNotFirstIntersecting() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: 1440, y: 0, width: 2560, height: 1440)]
        // Window straddles both displays but is mostly on the second one.
        let window = CGRect(x: 1340, y: 100, width: 1000, height: 600)
        XCTAssertEqual(ScreenGeometry.bestMatchIndex(for: window, in: frames), 1)
    }

    func testBestMatchNilWhenOffscreen() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        XCTAssertNil(ScreenGeometry.bestMatchIndex(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), in: frames))
    }

    func testPixelSizeScales() {
        let s = ScreenGeometry.pixelSize(forPointSize: CGSize(width: 1440, height: 900), scale: 2)
        XCTAssertEqual(s.width, 2880)
        XCTAssertEqual(s.height, 1800)
        let odd = ScreenGeometry.pixelSize(forPointSize: CGSize(width: 1000.5, height: 10), scale: 1.5)
        XCTAssertEqual(odd.width, 1501)
        XCTAssertEqual(ScreenGeometry.pixelSize(forPointSize: .zero, scale: 0).width, 1)
    }
}
