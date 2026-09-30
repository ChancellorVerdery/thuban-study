import CoreGraphics
import Foundation
import Vision

/// A page picture as an RGBA buffer, rows top-down (so a pixel rect is in the same top-left space as
/// `CGImage.cropping(to:)`).
struct PageBitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    func luminance(_ i: Int) -> Int {
        (Int(pixels[i * 4]) * 299 + Int(pixels[i * 4 + 1]) * 587 + Int(pixels[i * 4 + 2]) * 114) / 1000
    }

    func chroma(_ i: Int) -> Int {
        let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
        return max(r, g, b) - min(r, g, b)
    }

    func makeImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }
}

/// Removes print watermarks ("DO NOT COPY", "Printed by …" stamped across the page) from a page picture. They are
/// drawn in light, colourless grey; the page's own content is dark ink (text, lines) or colour (fills). Light grey
/// is wiped to white unless it touches dark ink — the anti-aliased edge of a letter or a line — so text and drawings
/// keep their shape.
public enum WatermarkRemover {
    /// Grey at or above this luminance (0–255) is watermark-coloured.
    static let lightGrey = 150
    /// Below this chroma a pixel counts as grey.
    static let greyChroma = 12
    /// Ink dark enough to protect its grey neighbours.
    static let darkInk = 110

    public static func clean(_ image: CGImage) -> CGImage? {
        guard var bitmap = PageBitmap(image) else { return nil }
        clean(&bitmap)
        return bitmap.makeImage()
    }

    /// The share of the page's pixels that were wiped (to tell a watermarked page from a clean one).
    @discardableResult
    static func clean(_ bitmap: inout PageBitmap) -> Double {
        let w = bitmap.width, h = bitmap.height
        var dark = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where bitmap.luminance(i) < darkInk { dark[i] = true }
        var wiped = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let l = bitmap.luminance(i)
                guard l >= lightGrey, l < 252, bitmap.chroma(i) < greyChroma else { continue }
                // Keep the grey rim of real ink.
                var nearInk = false
                search: for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < w else { continue }
                        if dark[yy * w + xx] { nearInk = true; break search }
                    }
                }
                guard !nearInk else { continue }
                bitmap.pixels[i * 4] = 255
                bitmap.pixels[i * 4 + 1] = 255
                bitmap.pixels[i * 4 + 2] = 255
                wiped += 1
            }
        }
        return Double(wiped) / Double(max(1, w * h))
    }
}

/// One recognized line of text, in pixel coordinates (top-left origin).
struct TextLine: Equatable {
    var text: String
    var rect: CGRect
}

/// Finds the figures on a page picture (a scan, or a page printed as one image): the regions of drawing — lines,
/// fills, labelled diagrams — that are not running text. Body-text lines are wide; a figure's labels are short and
/// sit among drawn ink, so a cluster of ink that is mostly not text is a figure, cropped with its labels.
public enum PageFigureFinder {
    /// A text line at least this share of the page wide is running text (never part of a figure).
    static let paragraphWidth = 0.45
    /// Grid cell (pixels) the ink is clustered on.
    static let cell = 6
    /// Cells of gap bridged when clustering (a figure's parts and labels join; paragraphs stay apart).
    static let bridge = 3
    /// Smallest figure, in pixels.
    static let minWidth = 90
    static let minHeight = 70
    /// A cluster whose ink is mostly inside text lines is text (an equation line, a list), not a figure.
    static let minDrawingShare = 0.35

    struct Found: Equatable {
        var rect: CGRect
        /// The caption under the figure ("FIGURE P1.28"), when there is one.
        var caption: String?
        /// The figure runs off the top or bottom of the picture: a page break cut it (see `cutEdges`).
        var touchesTop = false
        var touchesBottom = false
    }

    /// `cutEdges`: the picture's top and bottom are where a longer page was cut (a reader's print), so drawing that
    /// touches them is kept even when small — it is half of a figure the next or previous page completes.
    static func figures(in bitmap: PageBitmap, lines: [TextLine], cutEdges: Bool = false) -> [Found] {
        let w = bitmap.width, h = bitmap.height
        let paragraphs = lines.filter { $0.rect.width >= paragraphWidth * Double(w) }.map { $0.rect.insetBy(dx: -2, dy: -2) }
        let labels = lines.filter { $0.rect.width < paragraphWidth * Double(w) }
        let cols = (w + cell - 1) / cell, rows = (h + cell - 1) / cell
        // Running text is masked out before clustering.
        var masked = [Bool](repeating: false, count: w * h)
        for rect in paragraphs {
            let r = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { masked[y * w + x] = true } }
        }
        var ink = [Int](repeating: 0, count: cols * rows)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard !masked[i], bitmap.luminance(i) < 200 || bitmap.chroma(i) >= 25 else { continue }
                ink[(y / cell) * cols + (x / cell)] += 1
            }
        }
        let filled = ink.map { $0 >= 3 }
        // Bridge small gaps, then take connected clusters.
        var grown = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols where filled[r * cols + c] {
                for rr in max(0, r - bridge)...min(rows - 1, r + bridge) {
                    for cc in max(0, c - bridge)...min(cols - 1, c + bridge) { grown[rr * cols + cc] = true }
                }
            }
        }
        var seen = [Bool](repeating: false, count: cols * rows)
        var found: [Found] = []
        for start in 0..<(cols * rows) where grown[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minC = cols, maxC = 0, minR = rows, maxR = 0
            var inkCells = 0, textCells = 0
            while let index = stack.popLast() {
                let r = index / cols, c = index % cols
                if filled[index] {
                    minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                    inkCells += 1
                    let center = CGPoint(x: c * cell + cell / 2, y: r * cell + cell / 2)
                    if labels.contains(where: { $0.rect.insetBy(dx: -3, dy: -3).contains(center) }) { textCells += 1 }
                }
                for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let rr = r + dr, cc = c + dc
                    guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                    let next = rr * cols + cc
                    if grown[next] && !seen[next] { seen[next] = true; stack.append(next) }
                }
            }
            guard inkCells > 0 else { continue }
            var rect = CGRect(x: minC * cell, y: minR * cell, width: (maxC - minC + 1) * cell, height: (maxR - minR + 1) * cell)
            let drawingShare = 1 - Double(textCells) / Double(inkCells)
            let touchesTop = cutEdges && minR <= 2
            let touchesBottom = cutEdges && maxR >= rows - 3
            if touchesTop || touchesBottom {
                // Half a figure: any drawing wider than a sliver.
                guard rect.width >= 40, drawingShare >= minDrawingShare else { continue }
            } else {
                guard rect.width >= Double(minWidth), rect.height >= Double(minHeight), drawingShare >= minDrawingShare, inkCells >= 60 else { continue }
            }
            // Its labels, whole — but a long line of running text caught at the top is the problem statement above the
            // figure, not a label: the crop starts below it.
            for label in labels where label.rect.intersects(rect) { rect = rect.union(label.rect) }
            if let lead = lines.filter({ $0.rect.width >= 0.3 * Double(w) && $0.rect.intersects(rect) && $0.rect.midY < rect.minY + rect.height * 0.25 })
                .max(by: { $0.rect.maxY < $1.rect.maxY }), lead.rect.maxY + 4 < rect.maxY {
                // OCR boxes stop short of descenders: clear them too.
                let cut = lead.rect.maxY + lead.rect.height * 0.35 + 2
                rect = CGRect(x: rect.minX, y: cut, width: rect.width, height: rect.maxY - cut)
            }
            rect = rect.insetBy(dx: -8, dy: -8).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
            // A caption just below ("FIGURE P1.28", "Fig. 3.2").
            let caption = lines.first { line in
                line.rect.minY >= rect.maxY - 12 && line.rect.minY <= rect.maxY + 40
                    && line.rect.midX > rect.minX && line.rect.midX < rect.maxX
                    && line.text.range(of: #"^\s*(fig(ure)?\.?)\s*[A-Z]?\d"#, options: [.regularExpression, .caseInsensitive]) != nil
            }
            // A caption inside the cluster is trimmed off the crop.
            if let inside = lines.first(where: { rect.contains($0.rect) && $0.rect.maxY > rect.maxY - 40
                && $0.text.range(of: #"^\s*(fig(ure)?\.?)\s*[A-Z]?\d"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                // The caption's highlight box reaches a little above its text.
                rect.size.height = max(rect.height / 2, inside.rect.minY - rect.minY - 8)
                found.append(Found(rect: rect.integral, caption: inside.text, touchesTop: touchesTop, touchesBottom: false))
            } else {
                found.append(Found(rect: rect, caption: caption?.text, touchesTop: touchesTop, touchesBottom: touchesBottom))
            }
        }
        // Overlapping clusters are one figure.
        var merged: [Found] = []
        for figure in found.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            if let index = merged.firstIndex(where: { $0.rect.intersects(figure.rect) }) {
                merged[index].rect = merged[index].rect.union(figure.rect)
                merged[index].caption = merged[index].caption ?? figure.caption
                merged[index].touchesTop = merged[index].touchesTop || figure.touchesTop
                merged[index].touchesBottom = merged[index].touchesBottom || figure.touchesBottom
            } else {
                merged.append(figure)
            }
        }
        return merged
    }
}

extension VisionOCR {
    /// Recognized lines with their boxes in pixel coordinates (top-left origin), in reading order.
    static func recognizeLines(in image: CGImage) async throws -> [TextLine] {
        try await ParserSupport.offloaded {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw ThubanError.parse("Text recognition failed: \(error.localizedDescription)")
            }
            let w = Double(image.width), h = Double(image.height)
            return (request.results ?? [])
                .sorted { lhs, rhs in
                    let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
                    if abs(dy) > 0.008 { return dy > 0 }
                    return lhs.boundingBox.minX < rhs.boundingBox.minX
                }
                .compactMap { observation -> TextLine? in
                    guard let text = observation.topCandidates(1).first?.string else { return nil }
                    let box = observation.boundingBox
                    return TextLine(text: text, rect: CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h))
                }
        }
    }
}

/// Joins the two halves of a figure a page break cut: the part at the bottom of one page picture above the part at
/// the top of the next, over the columns both cover.
enum FigureStitcher {
    static func stitch(upper: CGImage, upperRect: CGRect, lower: CGImage, lowerRect: CGRect) -> CGImage? {
        let minX = min(upperRect.minX, lowerRect.minX), maxX = max(upperRect.maxX, lowerRect.maxX)
        let top = CGRect(x: minX, y: upperRect.minY, width: maxX - minX, height: CGFloat(upper.height) - upperRect.minY)
            .intersection(CGRect(x: 0, y: 0, width: upper.width, height: upper.height)).integral
        let bottom = CGRect(x: minX, y: 0, width: maxX - minX, height: lowerRect.maxY)
            .intersection(CGRect(x: 0, y: 0, width: lower.width, height: lower.height)).integral
        guard let topImage = upper.cropping(to: top), let bottomImage = lower.cropping(to: bottom) else { return nil }
        let width = max(topImage.width, bottomImage.width)
        let height = topImage.height + bottomImage.height
        guard let context = ImageCodec.rgbaContext(width: width, height: height) else { return nil }
        // CoreGraphics' origin is bottom-left: the lower half is drawn first, at the bottom.
        context.draw(bottomImage, in: CGRect(x: 0, y: 0, width: bottomImage.width, height: bottomImage.height))
        context.draw(topImage, in: CGRect(x: 0, y: bottomImage.height, width: topImage.width, height: topImage.height))
        return context.makeImage()
    }
}

extension PageFigureFinder {
    /// Whether a crop is big enough to be a figure on its own (a cut piece that found no other half must be).
    static func isFigureSized(_ rect: CGRect) -> Bool {
        rect.width >= Double(minWidth) && rect.height >= Double(minHeight)
    }
}
