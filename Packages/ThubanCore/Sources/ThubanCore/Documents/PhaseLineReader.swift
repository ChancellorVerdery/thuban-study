import Foundation
import CoreGraphics

/// A phase line (one-dimensional phase portrait): a single axis with its critical points marked and an arrow on
/// each stretch showing which way solutions move. Positions are fractions along the drawn line (0 = its top, or
/// its left end for a horizontal line), so the redraw keeps the original's proportions exactly.
public struct PhaseLine: Codable, Sendable, Equatable {
    public struct Mark: Codable, Sendable, Equatable {
        public var position: Double
        /// As printed ("0", "−1", "c"); empty for an unlabelled tick.
        public var text: String
        public init(position: Double, text: String) { self.position = position; self.text = text }
    }

    public struct Arrow: Codable, Sendable, Equatable {
        public var position: Double
        /// Towards larger values: up on a vertical line, right on a horizontal one.
        public var increasing: Bool
        public init(position: Double, increasing: Bool) { self.position = position; self.increasing = increasing }
    }

    public var vertical: Bool
    public var marks: [Mark]
    public var arrows: [Arrow]
    /// Where the line sits across the picture (0…1), and the name printed at its end, if any.
    public var offset: Double
    public var axisName: String?
    /// Where the line begins and ends along the picture (0…1).
    public var start: Double
    public var end: Double

    public init(vertical: Bool, marks: [Mark], arrows: [Arrow], offset: Double = 0.5, axisName: String? = nil, start: Double = 0.02, end: Double = 0.98) {
        self.vertical = vertical
        self.marks = marks
        self.arrows = arrows
        self.offset = offset
        self.axisName = axisName
        self.start = start
        self.end = end
    }

    /// A chart carrying this phase line.
    public var chart: StandardChart {
        var chart = StandardChart(chartType: "phaseLine", series: [], confidence: 0.9, provenance: StandardChart.traced)
        chart.phaseLine = self
        let points = marks.filter { !$0.text.isEmpty }.map(\.text).joined(separator: ", ")
        chart.verification = ChartVerification(passed: true, summary: "Read from the picture: a phase line with \(arrows.count) arrow\(arrows.count == 1 ? "" : "s")" + (points.isEmpty ? "." : " and critical points \(points)."))
        return chart
    }
}

/// Reads a phase line from its picture: exactly one long ink line (no crossing axis), the tick marks on it with
/// their labels, and the filled arrowheads along it — each arrow points to its narrow end.
public enum PhaseLineReader {
    public static func read(png: Data, caption: String? = nil) async -> PhaseLine? {
        guard let image = ImageCodec.image(from: png), let bitmap = GraphReader.Bitmap(image: image) else { return nil }
        let horizontals = GraphReader.longRuns(bitmap, horizontal: true).filter { Double($0.end - $0.start) >= Double(bitmap.width) * 0.7 }
        let verticals = GraphReader.longRuns(bitmap, horizontal: false).filter { Double($0.end - $0.start) >= Double(bitmap.height) * 0.7 }
        // One line and nothing crossing it.
        let vertical: Bool
        let line: GraphReader.Line
        if verticals.count == 1, horizontals.isEmpty { vertical = true; line = verticals[0] }
        else if horizontals.count == 1, verticals.isEmpty { vertical = false; line = horizontals[0] }
        else { return nil }

        let length = Double(line.end - line.start)
        func fraction(_ p: Double) -> Double { ((p - Double(line.start)) / length * 10_000).rounded() / 10_000 }

        // Ink across the line at each position along it: how far it reaches to either side.
        let across = vertical ? bitmap.width : bitmap.height
        func reach(_ q: Int, _ direction: Int) -> Int {
            var k = 1
            while k < 30 {
                let p = line.position + direction * k
                guard p >= 0, p < across else { break }
                let ink = vertical ? bitmap.isInk(p, q) : bitmap.isInk(q, p)
                if !ink { break }
                k += 1
            }
            return k - 1
        }
        let positions = Array(line.start...line.end)
        let left = positions.map { reach($0, -1) }, right = positions.map { reach($0, 1) }
        let baseline = [left, right].map { side in side.sorted()[side.count / 2] }.max() ?? 1

        // Arrowheads: runs where the ink reaches well past the line on both sides.
        var arrows: [PhaseLine.Arrow] = []
        var arrowSpans: [ClosedRange<Double>] = []
        var crossTicks: [Double] = []
        var i = 0
        while i < positions.count {
            guard min(left[i], right[i]) >= baseline + 2 else { i += 1; continue }
            var j = i
            while j + 1 < positions.count, min(left[j + 1], right[j + 1]) >= baseline + 2 { j += 1 }
            if j - i >= 3 {
                let widths = (i...j).map { left[$0] + right[$0] }
                let widest = widths.indices.max { widths[$0] < widths[$1] }!
                // The base is the wide end; the tip is the other end. Increasing = tip towards larger values
                // (up on screen for a vertical line, i.e. smaller row numbers; right for a horizontal one).
                let tipAtStart = widest > widths.count / 2
                let increasing = vertical ? tipAtStart : !tipAtStart
                arrows.append(PhaseLine.Arrow(position: fraction(Double(positions[i] + positions[j]) / 2), increasing: increasing))
                arrowSpans.append(Double(positions[i])...Double(positions[j]))
            } else if max(left[i], right[i]) <= 12 {
                // A short mark across both sides of the line is a tick, not an arrowhead.
                crossTicks.append(Double(positions[i] + positions[j]) / 2)
            }
            i = j + 1
        }
        guard !arrows.isEmpty else { return nil }

        // Tick marks: short ink reaching out on one side only.
        var ticks: [Double] = []
        for (k, q) in positions.enumerated() {
            let l = left[k], r = right[k]
            let oneSided = (l >= baseline + 2 && r <= baseline) || (r >= baseline + 2 && l <= baseline)
            guard oneSided, max(l, r) <= 12 else { continue }
            if let last = ticks.last, Double(q) - last <= 2 { continue }
            ticks.append(Double(q))
        }

        ticks = (ticks + crossTicks).sorted()
        // Labels beside the ticks (numbers or a symbol such as "c").
        let labels = (try? await GraphReader.recognizeLabels(in: image, horizontals: vertical ? [] : [line], verticals: vertical ? [line] : [])) ?? []
        // Marks: every label printed beside the line (at its tick when one is drawn there), then any tick left
        // unlabelled. Values must increase towards the top (or right): a label out of order that is in order when
        // negated lost its minus sign.
        var marks: [(position: Double, value: Double?, text: String)] = []
        var usedTicks: Set<Double> = []
        for label in labels where abs((vertical ? label.column : label.row) - Double(line.position)) <= 40 {
            let along = vertical ? label.row : label.column
            guard along >= Double(line.start) - 4, along <= Double(line.end) + 4 else { continue }
            let tick = ticks.min { abs($0 - along) < abs($1 - along) }
            let at = tick.flatMap { abs($0 - along) <= 10 ? $0 : nil } ?? along
            if let tick, abs(tick - along) <= 10 { usedTicks.insert(tick) }
            guard !marks.contains(where: { abs($0.position - at) < 4 }) else { continue }
            marks.append((at, label.symbolic ? nil : label.value, label.symbolic ? label.text : ""))
        }
        // An unlabelled "tick" touching an arrowhead is the head's own edge.
        for tick in ticks where !usedTicks.contains(tick) && !marks.contains(where: { abs($0.position - tick) < 4 })
            && !arrowSpans.contains(where: { tick >= $0.lowerBound - 8 && tick <= $0.upperBound + 8 }) {
            marks.append((tick, nil, ""))
        }
        marks.sort { $0.position < $1.position }
        // A tick with a glyph beside it that could not be read: when the caption names exactly one symbolic value
        // (a single letter such as "c", not x, y or f), that letter is its label.
        if let caption {
            let letters = Set(caption.split(whereSeparator: { !$0.isLetter }).map(String.init)
                .filter { $0.count == 1 && !["x", "y", "f", "t", "a", "A", "I"].contains($0) })
            if letters.count == 1, let letter = letters.first {
                for index in marks.indices where marks[index].value == nil && marks[index].text.isEmpty {
                    var ink = 0
                    let at = Int(marks[index].position)
                    for d in 4...32 {
                        for e in -8...8 {
                            let p = line.position - d, q = at + e
                            if vertical, p >= 0, q >= 0, q < bitmap.height, bitmap.isInk(p, q) { ink += 1 }
                            if !vertical, q >= 0, q < bitmap.width, line.position + d < bitmap.height, bitmap.isInk(q, line.position + d) { ink += 1 }
                        }
                    }
                    if ink >= 6 { marks[index].text = letter.lowercased() }
                }
            }
        }
        // Along a vertical line positions grow downwards and values upwards; along a horizontal one both grow rightwards.
        let numeric = marks.indices.filter { marks[$0].value != nil }
        for index in numeric {
            let value = marks[index].value!
            let others = numeric.filter { $0 != index }.map { (marks[$0].position, marks[$0].value!) }
            func inOrder(_ v: Double) -> Bool {
                others.allSatisfy { other in
                    let below = other.0 > marks[index].position
                    return vertical ? (below ? other.1 < v : other.1 > v) : (below ? other.1 > v : other.1 < v)
                }
            }
            if !inOrder(value), inOrder(-value) { marks[index].value = -value }
        }
        // Phase lines are drawn to scale: a label the others' straight line does not predict, but that fits once a
        // 6 and a 9 (the recogniser's usual confusion) are swapped, is the swapped value.
        if numeric.count >= 3 {
            for index in numeric {
                let others = numeric.filter { $0 != index }.map { (marks[$0].position, marks[$0].value!) }
                guard let fit = GraphReader.leastSquares(others.map { (value: $0.1, pixel: $0.0) }) else { continue }
                let predicted = (marks[index].position - fit.origin) / fit.scale
                let values = others.map(\.1) + [marks[index].value!]
                let range = max(1e-9, (values.max()! - values.min()!))
                let current = marks[index].value!
                guard abs(current - predicted) > 0.1 * range else { continue }
                let text = ChartGeometry.number(current)
                let swapped = String(text.map { $0 == "6" ? "9" : $0 == "9" ? "6" : $0 })
                if let alternative = Double(swapped), abs(alternative - predicted) <= 0.1 * range { marks[index].value = alternative }
            }
        }
        let phaseMarks = marks.map { mark -> PhaseLine.Mark in
            let text = mark.value.map { ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−") } ?? mark.text
            return PhaseLine.Mark(position: fraction(mark.position), text: text)
        }
        let offset = Double(line.position) / Double(vertical ? bitmap.width : bitmap.height)
        let extent = Double(vertical ? bitmap.height : bitmap.width)
        return PhaseLine(vertical: vertical, marks: phaseMarks, arrows: arrows.sorted { $0.position < $1.position }, offset: (offset * 1000).rounded() / 1000,
                         start: (Double(line.start) / extent * 1000).rounded() / 1000, end: (Double(line.end) / extent * 1000).rounded() / 1000)
    }
}
