import Foundation
import CoreGraphics
import Vision

/// The text a figure prints inside its plot — point labels "A(−1, 4)", vector names "a", "|u| = 2", angles "60°",
/// curve levels "16" — read from the picture and put back on a redrawn chart, so the redraw keeps the original's
/// labels instead of only its shapes.
public enum PictureText {
    /// One recognised run of text and its box in pixels (top-left origin).
    public struct Word: Sendable, Equatable {
        public var text: String
        public var rect: CGRect

        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    /// A point label lies beside its dot: farther than this (pixels) and the word belongs to something else.
    static let pointReach = 40.0
    /// A vector's name sits beside its shaft or head, a little farther out than a point's label.
    static let vectorReach = 60.0
    /// A number this close (pixels) to an axis line is one of the axis's tick labels.
    static let tickReach = 14.0
    /// Axis names, printed at the ends of the axes rather than about anything plotted.
    static let axisNames: Set<String> = ["x", "y", "t"]

    /// Every label printed in the picture. Labels are short, small and often not words ("a", "B(4, 5)"), so
    /// recognition runs in accurate mode with no language correction and no minimum text height. Vision skips a
    /// lone letter in a whole figure, so the glyph-sized ink no line of text covers is read a second time, enlarged
    /// and repeated (`GlyphSheet`). Empty when the picture cannot be decoded or holds no text.
    public static func words(in png: Data) async -> [Word] {
        guard let image = ImageCodec.image(from: png) else { return [] }
        return (try? await ParserSupport.offloaded {
            let found = try recognize(in: image)
            guard let bitmap = GraphReader.Bitmap(image: image) else { return found }
            return found + (try GlyphSheet.words(in: image, bitmap: bitmap, skipping: found.map(\.rect)))
        }) ?? []
    }

    /// The words Vision reads in `image`. Vision joins labels that share a row into one line ("A(−1, 4)   B(4, 5)"),
    /// so each line is split where the gap between its tokens is wider than a space.
    static func recognize(in image: CGImage) throws -> [Word] {
        let request = textRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).flatMap { observation -> [Word] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            return split(candidate, size: size).compactMap(cleaned)
        }
    }

    /// Accurate recognition of English text with no language correction and no minimum height. Without a fixed
    /// language Vision may read a lone italic "y" as Cyrillic "у".
    static func textRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        return request
    }

    /// The line's space-separated tokens, joined again wherever the gap between neighbours is under half the
    /// line's height (an ordinary space, as in "A(−1, 4)") — except two plain numbers, which are two labels side by
    /// side ("12 16" on neighbouring level curves), not one.
    private static func split(_ text: VNRecognizedText, size: CGSize) -> [Word] {
        var words: [Word] = []
        for token in tokens(of: text, size: size) {
            if let last = words.last, token.rect.minX - last.rect.maxX < 0.5 * max(last.rect.height, token.rect.height),
               !(isNumber(last.text) && isNumber(token.text)) {
                words[words.count - 1] = Word(text: last.text + " " + token.text, rect: last.rect.union(token.rect))
            } else {
                words.append(token)
            }
        }
        return words
    }

    /// A plain number as printed: "12", "−2.5".
    static func isNumber(_ text: String) -> Bool {
        Double(text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: " ", with: "")) != nil
    }

    /// The recognised line's space-separated tokens with their boxes in an image of `size` (pixels, top-left
    /// origin). Vision boxes whole tokens only: a box asked for one character of a token is the token's.
    static func tokens(of text: VNRecognizedText, size: CGSize) -> [Word] {
        let string = text.string
        var tokens: [Word] = []
        var start = string.startIndex
        while let first = string[start...].firstIndex(where: { !$0.isWhitespace }) {
            let end = string[first...].firstIndex(where: \.isWhitespace) ?? string.endIndex
            if let box = try? text.boundingBox(for: first..<end)?.boundingBox {
                let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                                  width: box.width * size.width, height: box.height * size.height)
                tokens.append(Word(text: String(string[first..<end]), rect: rect))
            }
            start = end
        }
        return tokens
    }

    /// Marks Vision reads as text but are drawing: a dot or arrowhead read as "•" or "*", a tick mark as "-".
    private static let strayMarks = CharacterSet(charactersIn: "-–—*•·\"'`_~.,:;")

    /// Cyrillic letters Vision sometimes returns for their Latin twins (an italic "y" read as "у").
    private static let latin: [Character: Character] = [
        "а": "a", "с": "c", "е": "e", "і": "i", "о": "o", "р": "p", "х": "x", "у": "y",
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "К": "K", "М": "M", "О": "O", "Р": "P", "Т": "T", "Х": "X", "У": "Y",
    ]

    /// A point named by its coordinates, "A(−1, 4)" or "(8, 0)".
    private static let coordinateLabel = #"[A-Za-z]?\(\s*[-−]?[\d.]+\s*,\s*[-−]?[\d.]+\s*\)"#

    /// `word` in Latin letters without the stray marks at its ends (and an opening bracket left unmatched), with
    /// "=" spaced evenly, or nil when nothing readable remains. A coordinate label keeps only itself: the dot or
    /// arrowhead beside it that Vision reads into the line ("1 A(5, 2)", "A(−1, 4) ad") is dropped.
    static func cleaned(_ word: Word) -> Word? {
        var text = String(word.text.map { latin[$0] ?? $0 }).trimmingCharacters(in: strayMarks.union(.whitespaces))
        // Only a trailing mark is dropped from a leading minus: "−2" keeps its sign, "10-" loses its tick.
        if word.text.trimmingCharacters(in: .whitespaces).first.map({ "-−".contains($0) }) == true,
           let first = text.first, first.isNumber {
            text = "-" + text
        }
        if text.hasPrefix("("), text.filter({ $0 == "(" }).count > text.filter({ $0 == ")" }).count {
            text.removeFirst()
        }
        if let range = text.range(of: coordinateLabel, options: .regularExpression),
           (text[..<range.lowerBound] + text[range.upperBound...]).filter({ !$0.isWhitespace }).count <= 2 {
            text = String(text[range])
        }
        text = text.replacingOccurrences(of: #"\s*=\s*"#, with: " = ", options: .regularExpression)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return Word(text: text, rect: word.rect)
    }

    /// `chart` with the picture's words attached: each marked point takes the nearest word beside it as its label,
    /// each vector the nearest short name by its shaft or head no point took, and every other word inside the plot
    /// box (`columns` × `rows`, pixels) becomes an annotation at its centre. Tick numbers along the axes and the
    /// axis names are left out, and no text is attached twice — nor any the chart already carries.
    static func attach(_ chart: StandardChart, words: [Word], reading: GraphReading, columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> StandardChart {
        var chart = chart
        var used = carriedTexts(chart)
        var free = words.filter { !isTickNumber($0, reading: reading) && !used.contains($0.text) }

        labelPoints(&chart, words: &free, used: &used, reading: reading)
        nameVectors(&chart, words: &free, used: &used, reading: reading)

        let box = CGRect(x: Double(columns.lowerBound), y: Double(rows.lowerBound),
                         width: Double(columns.upperBound - columns.lowerBound), height: Double(rows.upperBound - rows.lowerBound))
        var annotations = chart.annotations ?? []
        for word in free where box.contains(CGPoint(x: word.rect.midX, y: word.rect.midY))
            && !axisNames.contains(word.text.lowercased()) && !used.contains(word.text) {
            let centre = reading.data(column: word.rect.midX, row: word.rect.midY)
            annotations.append(ChartAnnotation(text: word.text, x: centre.x, y: centre.y))
            used.insert(word.text)
        }
        chart.annotations = annotations.isEmpty ? chart.annotations : annotations
        return chart
    }

    /// The texts the chart already prints: series labels, point labels and annotations.
    private static func carriedTexts(_ chart: StandardChart) -> Set<String> {
        var texts = Set(chart.annotations?.map(\.text) ?? [])
        for series in chart.series {
            if let label = series.label, !label.isEmpty { texts.insert(label) }
            texts.formUnion((series.labels ?? []).filter { !$0.isEmpty })
        }
        return texts
    }

    /// Gives each unlabelled point of a "point" series the nearest free word within `pointReach`. Pairs are taken
    /// closest first, so two neighbouring dots cannot both claim the word between them.
    private static func labelPoints(_ chart: inout StandardChart, words: inout [Word], used: inout Set<String>, reading: GraphReading) {
        struct Pair { var series: Int; var point: Int; var word: Int; var distance: Double }
        var pairs: [Pair] = []
        for (s, series) in chart.series.enumerated() where series.seriesKind == .point {
            for (p, point) in (series.points ?? []).enumerated() where point.count >= 2 && (series.labels?[safe: p] ?? "").isEmpty {
                let pixel = reading.pixel(x: point[0], y: point[1])
                for (w, word) in words.enumerated() {
                    let d = distance(from: CGPoint(x: pixel.column, y: pixel.row), to: word.rect)
                    if d <= pointReach { pairs.append(Pair(series: s, point: p, word: w, distance: d)) }
                }
            }
        }
        var claimed = Set<Int>(), labelled = Set<[Int]>()
        for pair in pairs.sorted(by: { $0.distance < $1.distance }) {
            let text = words[pair.word].text
            guard !claimed.contains(pair.word), !labelled.contains([pair.series, pair.point]), !used.contains(text) else { continue }
            let count = chart.series[pair.series].points?.count ?? 0
            var labels = chart.series[pair.series].labels ?? []
            labels += Array(repeating: "", count: max(0, count - labels.count))
            labels[pair.point] = text
            chart.series[pair.series].labels = labels
            claimed.insert(pair.word)
            labelled.insert([pair.series, pair.point])
            used.insert(text)
        }
        words = words.enumerated().filter { !claimed.contains($0.offset) }.map(\.element)
    }

    /// Gives each unnamed vector the nearest free name within `vectorReach` of its middle or head.
    private static func nameVectors(_ chart: inout StandardChart, words: inout [Word], used: inout Set<String>, reading: GraphReading) {
        for s in chart.series.indices where chart.series[s].seriesKind == .vector && (chart.series[s].label ?? "").isEmpty {
            guard let points = chart.series[s].points, points.count >= 2, points[0].count >= 2, points[1].count >= 2 else { continue }
            let tail = reading.pixel(x: points[0][0], y: points[0][1]), head = reading.pixel(x: points[1][0], y: points[1][1])
            let anchors = [CGPoint(x: (tail.column + head.column) / 2, y: (tail.row + head.row) / 2), CGPoint(x: head.column, y: head.row)]
            let nearest = words.indices
                .filter { isVectorName(words[$0].text) && !used.contains(words[$0].text) }
                .map { w in (w, anchors.map { distance(from: $0, to: words[w].rect) }.min() ?? .infinity) }
                .filter { $0.1 <= vectorReach }
                .min { $0.1 < $1.1 }
            guard let (w, _) = nearest else { continue }
            chart.series[s].label = words[w].text
            used.insert(words[w].text)
            words.remove(at: w)
        }
    }

    /// A vector's name: a short word with a letter ("a", "u", "AB"), or a statement about it ("|u| = 2").
    static func isVectorName(_ text: String) -> Bool {
        guard text.contains(where: \.isLetter), !axisNames.contains(text.lowercased()) else { return false }
        return text.count <= 3 || text.contains("|") || text.contains("=")
    }

    /// A number printed within `tickReach` of an axis line: one of that axis's tick labels. An axis whose zero is
    /// off the plot is drawn along the plot's edge, so the line is taken at zero clamped into the other axis's extent.
    static func isTickNumber(_ word: Word, reading: GraphReading) -> Bool {
        guard isNumber(word.text) else { return false }
        let xAxisRow = min(max(reading.y.pixel(0), reading.y.extent.lowerBound), reading.y.extent.upperBound)
        let yAxisColumn = min(max(reading.x.pixel(0), reading.x.extent.lowerBound), reading.x.extent.upperBound)
        let rowGap = max(word.rect.minY - xAxisRow, xAxisRow - word.rect.maxY, 0)
        let columnGap = max(word.rect.minX - yAxisColumn, yAxisColumn - word.rect.maxX, 0)
        return rowGap <= tickReach || columnGap <= tickReach
    }

    /// Pixels from `point` to the nearest edge of `rect` (0 inside it).
    static func distance(from point: CGPoint, to rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
        let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// The second reading of a figure's labels. Vision does not see a lone letter as text at all — not even enlarged
/// and set apart — but reads it once it repeats like a word ("uuu"). So each cluster of glyph-sized ink no
/// recognised line covers (a lone "a", "u", "E" beside a shape) is cut out, enlarged and set `copies` times side by
/// side in its own cell of one white sheet, which Vision reads in one pass; the text read in a cell is cut back
/// into its copies, which vote on the cluster's text.
enum GlyphSheet {
    /// Glyph-sized: no taller or wider than this (pixels). Lines, curves and axes are larger.
    static let largestGlyph = 48
    /// A cluster this short is a speck, a dot or a dash, not a character.
    static let shortestCluster = 6.0
    /// More clusters than this are a drawn field or a scatter, not labels: the sheet is not worth reading.
    static let mostClusters = 60
    /// Height each cluster is enlarged to on the sheet, and the cell around its copies.
    static let sheetGlyph = 32.0
    static let cellWidth = 640.0, cellHeight = 100.0, cellsAcross = 2
    static let copies = 3
    /// Space between copies, as a fraction of their height: about a letter's spacing, so they read as one word.
    static let copyGap = 0.15

    static func words(in image: CGImage, bitmap: GraphReader.Bitmap, skipping covered: [CGRect]) throws -> [PictureText.Word] {
        let boxes = glyphBoxes(bitmap).filter { box in !covered.contains { $0.insetBy(dx: -2, dy: -2).intersects(box) } }
        let groups = clusters(boxes).filter { $0.height >= shortestCluster }
        guard !groups.isEmpty, groups.count <= mostClusters, let sheet = sheet(of: groups, from: image) else { return [] }
        let request = PictureText.textRequest()
        try VNImageRequestHandler(cgImage: sheet, options: [:]).perform([request])
        let size = CGSize(width: sheet.width, height: sheet.height)
        var texts = [String](repeating: "", count: groups.count)
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for token in PictureText.tokens(of: candidate, size: size) {
                let cell = Int(token.rect.midY / cellHeight) * cellsAcross + Int(token.rect.midX / cellWidth)
                if texts.indices.contains(cell) { texts[cell] += token.text }
            }
        }
        return zip(texts, groups).compactMap { text, rect in
            vote(text).flatMap { PictureText.cleaned(PictureText.Word(text: $0, rect: rect)) }
        }
    }

    /// The cluster's text from what was read across its copies: the read text (spaces dropped) cut into `copies`
    /// equal parts, the part at least two of them agree on, ignoring case ("uuU" is "u"; the casing most of them
    /// read wins). Nil when the parts cannot be cut evenly or none agree.
    static func vote(_ text: String) -> String? {
        let letters = Array(text.filter { !$0.isWhitespace })
        guard !letters.isEmpty, letters.count % copies == 0 else { return nil }
        let length = letters.count / copies
        let parts = (0..<copies).map { String(letters[($0 * length)..<(($0 + 1) * length)]) }
        let groups: [[String]] = Array(Dictionary(grouping: parts, by: { $0.lowercased() }).values)
        guard let agreed = groups.max(by: { $0.count < $1.count }), agreed.count >= 2 else { return nil }
        // Equal counts go to the lowercase casing, the larger string.
        let casings: [(text: String, count: Int)] = Set(agreed).map { text in (text, agreed.filter { $0 == text }.count) }
        guard let casing = casings.max(by: { ($0.count, $0.text) < ($1.count, $1.text) }) else { return nil }
        return casing.text
    }

    /// Bounding boxes (pixels, top-left origin) of the 8-connected runs of ink that are glyph-sized. Ink is dark or
    /// strongly coloured: a pale tint shading the plot (a lake's blue) and gridlines are paper here, so the labels
    /// printed on them stand apart.
    static func glyphBoxes(_ bitmap: GraphReader.Bitmap) -> [CGRect] {
        let w = bitmap.width, h = bitmap.height
        var seen = [Bool](repeating: false, count: w * h)
        func isInk(_ k: Int) -> Bool {
            let p = bitmap.rgb(k % w, k / w)
            let hi = max(p.r, p.g, p.b), lo = min(p.r, p.g, p.b)
            return hi < 170 || hi - lo > 80
        }
        var boxes: [CGRect] = []
        for start in 0..<(w * h) where !seen[start] && isInk(start) {
            var stack = [start]
            seen[start] = true
            var minC = w, maxC = 0, minR = h, maxR = 0
            while let k = stack.popLast() {
                let c = k % w, r = k / w
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for dr in -1...1 { for dc in -1...1 where dr != 0 || dc != 0 {
                    let cc = c + dc, rr = r + dr
                    guard cc >= 0, cc < w, rr >= 0, rr < h else { continue }
                    let n = rr * w + cc
                    if !seen[n], isInk(n) { seen[n] = true; stack.append(n) }
                } }
            }
            guard maxC - minC < largestGlyph, maxR - minR < largestGlyph else { continue }
            boxes.append(CGRect(x: minC, y: minR, width: maxC - minC + 1, height: maxR - minR + 1))
        }
        return boxes
    }

    /// Boxes merged into the words they spell: two boxes join when they share a row band and the gap between them
    /// is under most of a character's height (the "|", "u", "|", "=", "2" of "|u| = 2"), or when one sits just over
    /// the other (the dot of an "i", the bars of "=").
    static func clusters(_ boxes: [CGRect]) -> [CGRect] {
        var groups = boxes
        var merged = true
        while merged {
            merged = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i && belong(groups[i], groups[j]) {
                    groups[i] = groups[i].union(groups[j])
                    groups.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return groups
    }

    private static func belong(_ a: CGRect, _ b: CGRect) -> Bool {
        let height = max(a.height, b.height, shortestCluster)
        let rowOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let columnOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let gap = max(a.minX - b.maxX, b.minX - a.maxX, 0)
        let verticalGap = max(a.minY - b.maxY, b.minY - a.maxY, 0)
        return (rowOverlap > 0.4 * min(a.height, b.height) && gap < 0.8 * height) || (columnOverlap > 0 && verticalGap < 0.3 * height)
    }

    /// One white sheet with each cluster cut from `image`, enlarged to `sheetGlyph` high and set `copies` times in a
    /// row in its cell (cells row by row, `cellsAcross` to a row), and where each copy landed (pixels, top-left
    /// origin): `slots[cluster][copy]`.
    static func sheet(of groups: [CGRect], from image: CGImage) -> CGImage? {
        let rows = (groups.count + cellsAcross - 1) / cellsAcross
        let height = Int(cellHeight) * rows
        guard let context = ImageCodec.rgbaContext(width: Int(cellWidth) * cellsAcross, height: height) else { return nil }
        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let widest = (cellWidth - 2 * sheetGlyph) / Double(copies) - sheetGlyph * copyGap
        var slots: [[CGRect]] = []
        for (index, group) in groups.enumerated() {
            let crop = group.insetBy(dx: -1, dy: -1).intersection(bounds).integral
            let scale = min(sheetGlyph / crop.height, widest / crop.width, 4)
            let size = CGSize(width: crop.width * scale, height: crop.height * scale)
            let gap = size.height * copyGap
            let run = Double(copies) * size.width + Double(copies - 1) * gap
            let column = Double(index % cellsAcross), row = Double(index / cellsAcross)
            let left = column * cellWidth + (cellWidth - run) / 2, top = row * cellHeight + (cellHeight - size.height) / 2
            let copySlots = (0..<copies).map { CGRect(x: left + Double($0) * (size.width + gap), y: top, width: size.width, height: size.height) }
            slots.append(copySlots)
            guard let piece = image.cropping(to: crop) else { continue }
            for slot in copySlots {
                // CoreGraphics' origin is bottom-left: the slot's top row is drawn from the sheet's top.
                context.draw(piece, in: CGRect(x: slot.minX, y: Double(height) - slot.maxY, width: slot.width, height: slot.height))
            }
        }
        return context.makeImage()
    }
}
