import Foundation
import CoreGraphics

/// What a plotted picture's ink says on its own: whether its curves are all one colour, whether the image holds
/// several plots side by side, and its separate curves (connected runs of curve ink) for fitting and checking.
public enum PictureInk {
    /// Every curve in the picture is one colour (or black): the redraw should be one colour too. Pictures with no
    /// coloured ink at all count as one colour.
    static func isMonochrome(_ bitmap: GraphReader.Bitmap) -> Bool {
        var bins = [Int](repeating: 0, count: 12), total = 0
        for row in Swift.stride(from: 0, to: bitmap.height, by: 2) {
            for column in Swift.stride(from: 0, to: bitmap.width, by: 2) {
                guard let bin = bitmap.hueBin(column, row) else { continue }
                bins[bin] += 1; total += 1
            }
        }
        guard total >= 60 else { return true }
        let best = (0..<12).max { bins[$0] < bins[$1] }!
        let around = bins[best] + bins[(best + 1) % 12] + bins[(best + 11) % 12]
        return Double(around) / Double(total) >= 0.9
    }

    public static func isMonochrome(png: Data) -> Bool? {
        guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image) else { return nil }
        return isMonochrome(bitmap)
    }

    /// The share of the picture covered by shading: tinted pixels (not paper, not dark ink) in solid patches, so a
    /// curve, a gridline or a label never counts. Nil when the image cannot be read.
    public static func shadedShare(png: Data) -> Double? {
        guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image) else { return nil }
        func tinted(_ c: Int, _ r: Int) -> Bool {
            let p = bitmap.rgb(c, r)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            return lo < 235 && hi >= 120 && (hi - lo > 18 || (hi < 225 && hi > 140))
        }
        var shaded = 0, total = 0
        let step = 4
        for r in Swift.stride(from: step, to: bitmap.height - step, by: step) {
            for c in Swift.stride(from: step, to: bitmap.width - step, by: step) {
                total += 1
                // A patch: the pixel and its four neighbours a few pixels away are all tinted.
                if tinted(c, r), tinted(c - 3, r), tinted(c + 3, r), tinted(c, r - 3), tinted(c, r + 3) { shaded += 1 }
            }
        }
        return total > 0 ? Double(shaded) / Double(total) : nil
    }

    /// The column spans of separate plots laid side by side (I, II, …): content separated by blank vertical bands.
    /// Empty when the picture is one plot.
    static func panelColumns(_ bitmap: GraphReader.Bitmap) -> [ClosedRange<Int>] {
        let w = bitmap.width, h = bitmap.height
        guard w >= 200, h >= 80 else { return [] }
        var profile = [Int](repeating: 0, count: w)
        for column in 0..<w {
            var n = 0
            for row in Swift.stride(from: 0, to: h, by: 1) where !bitmap.isBackground(column, row) { n += 1 }
            profile[column] = n
        }
        let blank = profile.map { Double($0) <= Double(h) * 0.01 }
        let minimumGap = max(8, w / 40)
        // Content spans between blank bands.
        var spans: [ClosedRange<Int>] = [], start: Int?, gap = 0
        for column in 0..<w {
            if !blank[column] {
                if start == nil { start = column }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap >= minimumGap { spans.append(s...(column - gap)); start = nil; gap = 0 }
            }
        }
        if let s = start { spans.append(s...(w - 1 - gap)) }
        let wide = spans.filter { $0.count >= w / 5 }
        return wide.count >= 2 ? wide : []
    }

    /// The picture cut into its side-by-side plots (PNG each), or nil when it is one plot.
    public static func panels(png: Data) -> [Data]? {
        guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image) else { return nil }
        let spans = panelColumns(bitmap)
        guard spans.count >= 2 else { return nil }
        let pad = max(4, bitmap.width / 100)
        let pieces = spans.compactMap { span -> Data? in
            let x0 = max(0, span.lowerBound - pad), x1 = min(bitmap.width, span.upperBound + 1 + pad)
            guard let crop = image.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: bitmap.height)) else { return nil }
            return ImageCodec.png(from: crop)
        }
        return pieces.count == spans.count ? pieces : nil
    }

    /// The picture's separate curves inside the plot area: 8-connected runs of curve ink (coloured ink when the
    /// picture has enough of it, else dark ink), off the axes, at least `minimum` pixels and not area-like (a
    /// shaded region or a block of text). Pixels as (column, row).
    static func curves(_ bitmap: GraphReader.Bitmap, columns: ClosedRange<Int>, rows: ClosedRange<Int>,
                       skip: (Int, Int) -> Bool, minimum: Int = 25, minimumExtent: Int? = nil) -> [[(Int, Int)]] {
        var coloured = 0
        for row in Swift.stride(from: rows.lowerBound, through: rows.upperBound, by: 2) {
            for column in Swift.stride(from: columns.lowerBound, through: columns.upperBound, by: 2) where bitmap.hueBin(column, row) != nil { coloured += 1 }
        }
        if coloured >= 50 {
            let found = components(bitmap, columns: columns, rows: rows, skip: skip, minimum: minimum, minimumExtent: minimumExtent, useColour: true)
            // All the colour was shading: the curves are the dark boundary lines.
            if !found.isEmpty { return found }
        }
        return components(bitmap, columns: columns, rows: rows, skip: skip, minimum: minimum, minimumExtent: minimumExtent, useColour: false)
    }

    private static func components(_ bitmap: GraphReader.Bitmap, columns: ClosedRange<Int>, rows: ClosedRange<Int>,
                                   skip: (Int, Int) -> Bool, minimum: Int, minimumExtent: Int?, useColour: Bool) -> [[(Int, Int)]] {
        let w = columns.count, h = rows.count
        var mask = [Bool](repeating: false, count: w * h)
        var hue = [Int8](repeating: -1, count: w * h)
        for row in rows { for column in columns where !skip(column, row) {
            let k = (row - rows.lowerBound) * w + (column - columns.lowerBound)
            if useColour {
                if let bin = bitmap.hueBin(column, row) { mask[k] = true; hue[k] = Int8(bin) }
            } else if bitmap.isInk(column, row) {
                mask[k] = true
            }
        } }
        // Neighbours join only when their hues are within one bin (always, for dark ink).
        func sameColour(_ a: Int, _ b: Int) -> Bool {
            guard hue[a] >= 0, hue[b] >= 0 else { return true }
            let d = abs(Int(hue[a]) - Int(hue[b]))
            return min(d, 12 - d) <= 1
        }
        var seen = [Bool](repeating: false, count: w * h)
        var result: [[(Int, Int)]] = []
        let span = max(w, h)
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            var stack = [start], pixels: [(Int, Int)] = []
            seen[start] = true
            var minC = Int.max, maxC = Int.min, minR = Int.max, maxR = Int.min
            while let k = stack.popLast() {
                let c = k % w, r = k / w
                pixels.append((c + columns.lowerBound, r + rows.lowerBound))
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
                    let cc = c + dc, rr = r + dr
                    guard cc >= 0, cc < w, rr >= 0, rr < h else { continue }
                    let n = rr * w + cc
                    if mask[n], !seen[n], sameColour(k, n) { seen[n] = true; stack.append(n) }
                } }
            }
            guard pixels.count >= minimum else { continue }
            let boxW = maxC - minC + 1, boxH = maxR - minR + 1
            // Too small to be a curve (a label), or filling its box (shading, a blob of text).
            guard max(boxW, boxH) >= (minimumExtent ?? span / 25) else { continue }
            let fill = Double(pixels.count) / Double(boxW * boxH)
            guard fill < 0.35 || min(boxW, boxH) < 6 else { continue }
            result.append(pixels)
        }
        return result
    }
}
