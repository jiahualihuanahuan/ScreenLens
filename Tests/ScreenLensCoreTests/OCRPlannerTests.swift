import XCTest
@testable import ScreenLensCore

private struct Box: OCRBoxed {
    let ocrBox: CGRect
    let ocrConfidence: Float
    let text: String
    var ocrTextLength: Int { text.count }
}

final class OCRPlannerTests: XCTestCase {
    private func assertCoversImage(_ passes: [OCRPassSpec], w: Int, h: Int, file: StaticString = #filePath, line: UInt = #line) {
        // Every pixel of the image must be inside at least one detail crop.
        let crops = passes.filter { $0.kind == .detail }.map(\.crop)
        XCTAssertFalse(crops.isEmpty, file: file, line: line)
        for fx in stride(from: 0.0, through: 1.0, by: 0.05) {
            for fy in stride(from: 0.0, through: 1.0, by: 0.05) {
                let p = CGPoint(x: min(Double(w - 1), fx * Double(w)), y: min(Double(h - 1), fy * Double(h)))
                XCTAssertTrue(crops.contains { $0.contains(p) }, "uncovered \(p)", file: file, line: line)
            }
        }
        for c in crops {
            XCTAssertGreaterThanOrEqual(c.minX, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(c.minY, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(c.maxX, CGFloat(w), file: file, line: line)
            XCTAssertLessThanOrEqual(c.maxY, CGFloat(h), file: file, line: line)
            XCTAssertEqual(c, c.integral, file: file, line: line)
        }
    }

    func testCommonMacPanelsAreFullyCoveredAndBounded() {
        // (pixel size, backing scale): 13" Air, 14" MBP, 16" MBP, 5K Studio Display, 1080p external, 6K XDR
        let displays: [(Int, Int, CGFloat)] = [
            (2560, 1664, 2), (3024, 1964, 2), (3456, 2234, 2), (5120, 2880, 2), (1920, 1080, 1), (6016, 3384, 2),
            (1280, 800, 1), (7680, 4320, 2)
        ]
        for (w, h, scale) in displays {
            for passes in [OCRPlanner.wordSearchPasses(pixelWidth: w, pixelHeight: h, pointPixelScale: scale),
                           OCRPlanner.translationPasses(pixelWidth: w, pixelHeight: h, pointPixelScale: scale)] {
                assertCoversImage(passes, w: w, h: h)
                for p in passes {
                    let out = max(p.crop.width, p.crop.height) * p.outputScale
                    XCTAssertLessThanOrEqual(out, OCRPlanner.maxPassEdge + 1, "\(w)x\(h) \(p.kind)")
                    XCTAssertGreaterThan(p.minimumTextHeight, 0)
                    XCTAssertLessThan(p.minimumTextHeight, 0.2 + 0.0001)
                }
            }
        }
    }

    func testSmallDisplayIsOneTileUpscaled() {
        let passes = OCRPlanner.detailPasses(pixelWidth: 1440, pixelHeight: 900, pointPixelScale: 1, maxTile: 2200)
        XCTAssertEqual(passes.count, 1)
        XCTAssertEqual(passes[0].outputScale, 2.0)
    }

    func testRetinaGetsSmallerUpscaleThanNonRetina() {
        XCTAssertGreaterThan(OCRPlanner.detailUpscale(pointPixelScale: 1), OCRPlanner.detailUpscale(pointPixelScale: 2))
    }

    func testWordSearchHasGiantAndSmallPasses() {
        let passes = OCRPlanner.wordSearchPasses(pixelWidth: 2880, pixelHeight: 1800, pointPixelScale: 2)
        XCTAssertTrue(passes.contains { $0.kind == .giant })
        XCTAssertTrue(passes.contains { $0.kind == .large })
        XCTAssertTrue(passes.contains { $0.kind == .macro })
        XCTAssertTrue(passes.contains { $0.kind == .detail })
        // Small text pass asks Vision for far smaller text than the giant pass.
        let detail = passes.first { $0.kind == .detail }!
        let giant = passes.first { $0.kind == .giant }!
        XCTAssertLessThan(detail.minimumTextHeight, 0.01)
        XCTAssertGreaterThan(giant.minimumTextHeight, 0.05)
    }

    func testNoDownscalePassesWhenImageAlreadySmall() {
        let passes = OCRPlanner.translationPasses(pixelWidth: 900, pixelHeight: 600, pointPixelScale: 1)
        XCTAssertFalse(passes.contains { $0.kind == .large })
    }

    func testNormalizedMappingFlipsToBottomLeft() {
        // Top-left quadrant of a 1000x500 image.
        let spec = OCRPassSpec(kind: .detail, crop: CGRect(x: 0, y: 0, width: 500, height: 250),
                               outputScale: 2, minimumTextHeight: 0.01)
        let n = spec.normalizedRect(imageWidth: 1000, imageHeight: 500)
        XCTAssertEqual(n, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5))
        // A box in the bottom-left of that tile sits at the vertical middle of the full image.
        let mapped = spec.mapToFullImage(CGRect(x: 0, y: 0, width: 0.5, height: 0.2), imageWidth: 1000, imageHeight: 500)
        XCTAssertEqual(mapped.origin.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mapped.height, 0.1, accuracy: 1e-9)
        XCTAssertEqual(mapped.width, 0.25, accuracy: 1e-9)
    }

    func testAxisSegmentsOverlapAndCover() {
        let segs = OCRPlanner.axisSegments(length: 5120, maxTile: 2200, overlap: 160)
        XCTAssertEqual(segs.first?.start, 0)
        XCTAssertEqual(segs.last.map { $0.start + $0.length }, 5120)
        for i in 1..<segs.count {
            XCTAssertLessThan(segs[i].start, segs[i - 1].start + segs[i - 1].length, "tiles must overlap")
        }
        for s in segs { XCTAssertLessThanOrEqual(s.length, 2200 + 160) }
    }

    func testDedupeKeepsBetterScoredDuplicate() {
        let a = Box(ocrBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), ocrConfidence: 0.5, text: "hello")
        let b = Box(ocrBox: CGRect(x: 0.101, y: 0.101, width: 0.2, height: 0.05), ocrConfidence: 0.9, text: "hello")
        let out = OCRDedupe.deduplicate([a, b])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].ocrConfidence, 0.9)
    }

    func testDedupeMergesFragmentIntoWholeWord() {
        let whole = Box(ocrBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.2), ocrConfidence: 0.7, text: "HELLO")
        let fragment = Box(ocrBox: CGRect(x: 0.3, y: 0.4, width: 0.15, height: 0.2), ocrConfidence: 0.95, text: "LL")
        for input in [[whole, fragment], [fragment, whole]] {
            let out = OCRDedupe.deduplicate(input)
            XCTAssertEqual(out.map(\.text), ["HELLO"])
        }
    }

    func testDedupeKeepsNeighbouringWords() {
        let a = Box(ocrBox: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.03), ocrConfidence: 0.9, text: "big")
        let b = Box(ocrBox: CGRect(x: 0.21, y: 0.1, width: 0.1, height: 0.03), ocrConfidence: 0.9, text: "text")
        XCTAssertEqual(OCRDedupe.deduplicate([a, b]).count, 2)
    }

    func testDedupeKeepsSeparateLinesInsideATallMergedBox() {
        let tall = Box(ocrBox: CGRect(x: 0.1, y: 0.50, width: 0.5, height: 0.10), ocrConfidence: 0.9,
                       text: "Heading and the line below it")
        let line1 = Box(ocrBox: CGRect(x: 0.1, y: 0.55, width: 0.4, height: 0.04), ocrConfidence: 0.85, text: "Heading")
        let line2 = Box(ocrBox: CGRect(x: 0.1, y: 0.50, width: 0.4, height: 0.04), ocrConfidence: 0.85, text: "the line below")
        for input in [[tall, line1, line2], [line1, line2, tall]] {
            let out = OCRDedupe.deduplicate(input)
            XCTAssertTrue(out.contains { $0.text == "Heading" })
            XCTAssertTrue(out.contains { $0.text == "the line below" })
        }
    }
}
