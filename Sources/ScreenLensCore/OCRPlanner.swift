import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One Vision text-recognition pass over (part of) a captured image.
public struct OCRPassSpec: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Native-resolution tiles, upscaled: finds small body text and footnotes.
        case detail
        /// Whole image at (at most) native resolution: medium text and headings.
        case macro
        /// Whole image downscaled: large headings.
        case large
        /// Whole image heavily downscaled: giant hero text that Vision cannot see at full size.
        case giant
    }

    public let kind: Kind
    /// Crop in source-image PIXELS, top-left origin, integral, always inside the image.
    public let crop: CGRect
    /// Scale applied to the crop before it is handed to Vision (>1 upscales, <1 downscales).
    public let outputScale: CGFloat
    /// Value for `VNRecognizeTextRequest.minimumTextHeight` (fraction of the pass image height).
    public let minimumTextHeight: Float

    public init(kind: Kind, crop: CGRect, outputScale: CGFloat, minimumTextHeight: Float) {
        self.kind = kind
        self.crop = crop
        self.outputScale = outputScale
        self.minimumTextHeight = minimumTextHeight
    }

    /// Rect of the crop in Vision-normalized coordinates of the FULL image (bottom-left origin).
    public func normalizedRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        return CGRect(x: crop.origin.x / w,
                      y: 1.0 - (crop.origin.y + crop.height) / h,
                      width: crop.width / w,
                      height: crop.height / h)
    }

    /// Maps a Vision box that is normalized to this pass's image into normalized coordinates of
    /// the full source image.
    public func mapToFullImage(_ local: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let tile = normalizedRect(imageWidth: imageWidth, imageHeight: imageHeight)
        return CGRect(x: tile.origin.x + local.origin.x * tile.width,
                      y: tile.origin.y + local.origin.y * tile.height,
                      width: local.width * tile.width,
                      height: local.height * tile.height)
    }
}

/// Chooses which OCR passes to run for a capture, based on its real pixel size and the display's
/// pixel-per-point scale instead of hardcoded 1440x900 assumptions.
public enum OCRPlanner {
    /// Longest edge (pixels) we ever hand to Vision after scaling. Keeps memory bounded on 6K/8K displays.
    public static let maxPassEdge: CGFloat = 6144
    /// Smallest glyph (native pixels) we want Vision to consider. Roughly 6pt text on a 1x display.
    public static let minGlyphPixels: CGFloat = 5

    /// Upscale for small-text tiles. Non-retina text is only a few pixels tall and needs more help.
    public static func detailUpscale(pointPixelScale: CGFloat) -> CGFloat {
        if pointPixelScale < 1.5 { return 2.0 }
        if pointPixelScale < 2.5 { return 1.5 }
        return 1.0
    }

    /// Fraction of the pass image height for `minimumTextHeight`.
    public static func minimumTextHeight(minGlyphPixels glyph: CGFloat, passSourceHeight: CGFloat) -> Float {
        guard passSourceHeight > 0 else { return 0 }
        let v = glyph / passSourceHeight
        return Float(min(max(v, 0.0015), 0.2))
    }

    /// Splits `length` pixels into overlapping segments no longer than about `maxTile + overlap`.
    public static func axisSegments(length: Int, maxTile: Int, overlap: Int) -> [(start: Int, length: Int)] {
        guard length > 0 else { return [] }
        let count = max(1, Int((Double(length) / Double(max(maxTile, 1))).rounded(.up)))
        if count == 1 { return [(0, length)] }
        let core = Int((Double(length) / Double(count)).rounded(.up))
        var out: [(Int, Int)] = []
        for i in 0..<count {
            let start = max(0, i * core - overlap / 2)
            let end = min(length, (i + 1) * core + overlap / 2)
            if end > start { out.append((start, end - start)) }
        }
        return out
    }

    /// Native-resolution tiles for small text. A small capture becomes one tile; a 5K capture
    /// becomes a handful of overlapping tiles, each upscaled for the recognizer.
    public static func detailPasses(pixelWidth: Int,
                                    pixelHeight: Int,
                                    pointPixelScale: CGFloat,
                                    maxTile: Int,
                                    overlap: Int = 160) -> [OCRPassSpec] {
        guard pixelWidth > 0, pixelHeight > 0 else { return [] }
        let xs = axisSegments(length: pixelWidth, maxTile: maxTile, overlap: overlap)
        let ys = axisSegments(length: pixelHeight, maxTile: maxTile, overlap: overlap)
        let upscale = detailUpscale(pointPixelScale: pointPixelScale)
        var passes: [OCRPassSpec] = []
        for y in ys {
            for x in xs {
                let crop = CGRect(x: x.start, y: y.start, width: x.length, height: y.length)
                let longEdge = CGFloat(max(x.length, y.length))
                let scale = min(upscale, maxPassEdge / longEdge)
                passes.append(OCRPassSpec(
                    kind: .detail,
                    crop: crop,
                    outputScale: scale,
                    minimumTextHeight: minimumTextHeight(minGlyphPixels: minGlyphPixels,
                                                         passSourceHeight: CGFloat(y.length))
                ))
            }
        }
        return passes
    }

    private static func wholeImagePass(kind: OCRPassSpec.Kind,
                                       pixelWidth: Int,
                                       pixelHeight: Int,
                                       maxEdge: CGFloat,
                                       minimumTextHeight: Float) -> OCRPassSpec? {
        let longEdge = CGFloat(max(pixelWidth, pixelHeight))
        // Only downscale: upscaling the whole image is the job of the detail tiles.
        let scale = min(1.0, maxEdge / longEdge)
        if kind != .macro && scale >= 0.98 { return nil }
        return OCRPassSpec(kind: kind,
                           crop: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                           outputScale: scale,
                           minimumTextHeight: minimumTextHeight)
    }

    /// Passes for translate-in-place: small text (detail) plus a downscaled pass for big headings.
    public static func translationPasses(pixelWidth: Int, pixelHeight: Int, pointPixelScale: CGFloat) -> [OCRPassSpec] {
        var passes = detailPasses(pixelWidth: pixelWidth,
                                  pixelHeight: pixelHeight,
                                  pointPixelScale: pointPixelScale,
                                  maxTile: 3000)
        if let large = wholeImagePass(kind: .large, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      maxEdge: 1400, minimumTextHeight: 0.024) {
            passes.append(large)
        }
        return passes
    }

    /// Passes for select-and-search. Covers tiny footnotes through giant hero banners.
    public static func wordSearchPasses(pixelWidth: Int, pixelHeight: Int, pointPixelScale: CGFloat) -> [OCRPassSpec] {
        var passes: [OCRPassSpec] = []
        if let giant = wholeImagePass(kind: .giant, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      maxEdge: 640, minimumTextHeight: 0.08) {
            passes.append(giant)
        }
        if let large = wholeImagePass(kind: .large, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      maxEdge: 1100, minimumTextHeight: 0.035) {
            passes.append(large)
        }
        if let macro = wholeImagePass(kind: .macro, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                      maxEdge: 2200, minimumTextHeight: 0.011) {
            passes.append(macro)
        }
        passes.append(contentsOf: detailPasses(pixelWidth: pixelWidth,
                                               pixelHeight: pixelHeight,
                                               pointPixelScale: pointPixelScale,
                                               maxTile: 2200))
        return passes
    }
}

/// Anything OCR produces that can be de-duplicated across overlapping passes.
public protocol OCRBoxed {
    /// Vision-normalized box in the full image.
    var ocrBox: CGRect { get }
    var ocrConfidence: Float { get }
    var ocrTextLength: Int { get }
}

public enum OCRDedupe {
    private static func area(_ r: CGRect) -> CGFloat { max(r.width, 0) * max(r.height, 0) }

    public static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = area(inter)
        let unionArea = area(a) + area(b) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// Fraction of `inner` covered by `outer`.
    public static func coverage(of inner: CGRect, by outer: CGRect) -> CGFloat {
        let inter = inner.intersection(outer)
        if inter.isNull { return 0 }
        let a = area(inner)
        return a > 0 ? area(inter) / a : 0
    }

    /// Removes the same text found by several passes.
    ///  * Boxes that overlap strongly (IoU) are duplicates; the better-scored one survives.
    ///  * A fragment mostly covered by a bigger box is a duplicate (a tile boundary or a different scale
    ///    cut the text differently). If the surviving fragment is shorter than the newcomer that covers it,
    ///    the newcomer replaces it, so a split "HE" + "LLO" collapses to "HELLO".
    public static func deduplicate<T: OCRBoxed>(_ items: [T],
                                               iouThreshold: CGFloat = 0.5,
                                               coverageThreshold: CGFloat = 0.65) -> [T] {
        let sorted = items.sorted {
            if abs($0.ocrConfidence - $1.ocrConfidence) > 0.08 { return $0.ocrConfidence > $1.ocrConfidence }
            return $0.ocrTextLength > $1.ocrTextLength
        }
        var kept: [T] = []
        for item in sorted {
            var handled = false
            for (i, existing) in kept.enumerated() {
                let sameBox = iou(existing.ocrBox, item.ocrBox) > iouThreshold
                // Containment only means "same text" when both boxes are about one line tall. A tall
                // multi-line box (e.g. from the downscaled pass) must not swallow separate lines inside it.
                let heightRatio = item.ocrBox.height / max(existing.ocrBox.height, .leastNonzeroMagnitude)
                let similarHeight = heightRatio >= 0.6 && heightRatio <= 1 / 0.6
                let itemInsideExisting = similarHeight
                    && coverage(of: item.ocrBox, by: existing.ocrBox) > coverageThreshold
                let existingInsideItem = similarHeight
                    && coverage(of: existing.ocrBox, by: item.ocrBox) > coverageThreshold
                if sameBox || itemInsideExisting {
                    handled = true
                    break
                }
                if existingInsideItem && Double(item.ocrTextLength) >= Double(existing.ocrTextLength) * 1.4 {
                    kept[i] = item
                    handled = true
                    break
                }
            }
            if !handled { kept.append(item) }
        }
        return kept
    }
}
