import Foundation

public enum FigureKind: String, Codable, Sendable, CaseIterable {
    case chart, diagram, photo, table, unknown
}

public enum FigureStatus: String, Codable, Sendable, CaseIterable {
    case pending, reviewing, accepted, keptOriginal, skipped
}

public enum ChartSeriesKind: String, Sendable { case curve, region, level, parametric, point, vector, segment, angle }

/// Text the original prints inside the plot (a curve's label "16", a vector's name "a", "|u| = 2", "60°"), at a
/// data position.
public struct ChartAnnotation: Codable, Sendable, Equatable {
    public var text: String
    public var x: Double
    public var y: Double
    public init(text: String, x: Double, y: Double) { self.text = text; self.x = x; self.y = y }
}

/// One series of a `StandardChart`: a table of `[x, y]` points, a LaTeX function of x (or relation), a shaded
/// region, level curves, or a parametric curve (`kind`).
public struct ChartSeries: Codable, Sendable, Equatable {
    public var name: String
    /// `[[x, y], …]`
    public var points: [[Double]]?
    /// A function of x, e.g. "2x+1".
    public var latex: String?
    /// Optional hex color; `nil` = theme accent.
    public var color: String?
    /// Slope fields: a point `[x0, y0]` the solution curve passes through (the initial condition). The app
    /// integrates `dy/dx = slope` through it, so the curve follows the field exactly.
    public var through: [Double]?
    /// "solid" (default) | "dashed" | "dotted" — how the curve is drawn in the original.
    public var style: String?
    /// `[xMin, xMax]`: the stretch of x a solution curve is drawn over (nil: the whole window).
    public var domain: [Double]?
    /// What the series is (nil = "curve": a function of x or a relation in `latex`, or `points`):
    /// - "region": a shaded area, the points where every condition in `latex` holds ("x^2+y^2\le 49, x\ge 0");
    /// - "level": the level curves `latex` = c of a function of x and y, one for each value in `levels`;
    /// - "parametric": the curve (`xt`, `yt`) for t in `tRange`, with arrows along it when `directionArrows`;
    /// - "point": marked points `points`, drawn as dots (with `labels`);
    /// - "vector": an arrow from `points[0]` to `points[1]` (a position or tangent vector, a segment AB);
    /// - "segment": a plain line through `points` (a side of a triangle, a diagonal), no arrowhead;
    /// - "angle": an angle mark at vertex `points[0]` between the rays to `points[1]` and `points[2]` (a right angle
    ///   when `rightAngle`), with `labels[0]` ("60°") beside it.
    /// Every kind may carry a `label` printed beside it (a vector's name "a", a curve's level "16").
    public var kind: String?
    public var levels: [Double]?
    public var xt: String?
    public var yt: String?
    public var tRange: [Double]?
    public var directionArrows: Bool?
    /// kind "parametric": a parameter value t₀ the picture marks; the app draws the dot r(t₀) and, when asked, the
    /// position vector from the origin to it and the tangent vector r′(t₀) from it (computed, never estimated).
    public var markAt: Double?
    public var positionVector: Bool?
    public var tangentVector: Bool?
    /// A short name printed beside the series in the original ("a", "u", "16").
    public var label: String?
    /// kind "angle": a right-angle box instead of an arc.
    public var rightAngle: Bool?
    /// kind "segment" / "vector": tick marks across the middle (equal-length marks), 0 for none.
    public var ticks: Int?
    /// Arrowheads as the picture draws them, `[x, y, dx, dy]` (`MarkerReader`): drawn instead of evenly spaced ones,
    /// so a curve traced out and back keeps its two opposite arrows.
    public var arrowMarks: [[Double]]?
    /// kind "point": a label for each point as the original prints it ("A", "(8, 0)", "t = 1"); empty for none.
    public var labels: [String]?

    public var seriesKind: ChartSeriesKind { ChartSeriesKind(rawValue: (kind ?? "curve").lowercased()) ?? .curve }

    public init(name: String, points: [[Double]]? = nil, latex: String? = nil, color: String? = nil, through: [Double]? = nil, style: String? = nil) {
        self.name = name
        self.points = points
        self.latex = latex
        self.color = color
        self.through = through
        self.style = style
    }

    /// The initial condition as a pair, when well-formed.
    public var throughPoint: (x: Double, y: Double)? {
        guard let through, through.count == 2, through[0].isFinite, through[1].isFinite else { return nil }
        return (through[0], through[1])
    }
}

/// The app's check of a chart's stated equation against the points the agent read off the picture
/// (`FigureVerifier`).
public struct ChartVerification: Codable, Sendable, Equatable {
    public var passed: Bool
    /// One or two sentences a student can read: what was checked and, on a mismatch, where it went wrong.
    public var summary: String

    public init(passed: Bool, summary: String) {
        self.passed = passed
        self.summary = summary
    }
}

/// A label printed along an axis: its value and the text as printed ("1.7", "−2.2", "c").
public struct ChartTick: Codable, Sendable, Equatable {
    public var value: Double
    public var text: String
    public init(value: Double, text: String) { self.value = value; self.text = text }
}

/// One initial condition the question offers for a slope field's solution curve, so the app can test each
/// against the drawn curve (`FigureReconciler`).
public struct ChartCandidate: Codable, Sendable, Equatable {
    public var label: String
    public var x: Double
    public var y: Double

    public init(label: String, x: Double, y: Double) {
        self.label = label
        self.x = x
        self.y = y
    }
}

/// Standardized chart: everything needed to redraw the figure in the app's own graph style (Desmos-style expressions or
/// a table of series). This is the "one graph style across the app" representation.
public struct StandardChart: Codable, Sendable, Equatable {
    /// `provenance` value: the equation was found in the question text.
    public static let stated = "stated"
    /// `provenance` value: nothing in the question defines the curve, so it was read off the picture as points.
    public static let traced = "traced"

    /// "line" | "scatter" | "bar" | "function" | "histogram" | "slopeField"
    public var chartType: String
    public var xLabel: String?
    public var yLabel: String?
    /// Curves, dots or bars; for a slope field, the solution curves drawn over it.
    public var series: [ChartSeries]
    public var xRange: [Double]?
    public var yRange: [Double]?
    /// 0–1 from the agent.
    public var confidence: Double
    /// Slope fields only: the right-hand side of `dy/dx = f(x, y)` in LaTeX ("x-y", "\\sin(x)y").
    public var slope: String?
    /// Slope fields only: arrowheads (a direction field) rather than plain ticks. Default true.
    public var arrows: Bool
    /// Tick / gridline spacing on each axis as the original shows it (nil = let the grapher choose).
    public var xStep: Double?
    public var yStep: Double?
    /// Slope fields only: how many arrows the original draws across (columns) and down (rows).
    public var fieldColumns: Int?
    public var fieldRows: Int?
    /// Anything else needed to reproduce the picture (marked points, where a curve enters and leaves, what is
    /// dashed, which quadrant is shown …), as the agent saw it.
    public var notes: String?
    /// Where the equation came from: `StandardChart.stated` (found in the question) or `StandardChart.traced`
    /// (no definition anywhere in the question; the curve is a series of points read off the picture).
    public var provenance: String?
    /// The definition as the question states it, quoted ("part (b): dy/dx = x − y, y(0) = 1"). Empty when traced.
    public var definition: String?
    /// Points the agent read off the picture to test the stated equation: `[x, y]` on a curve, `[x, y, m]` for the
    /// slope `m` of the arrow at `(x, y)` in a field. The app evaluates the equation at each (`FigureVerifier`).
    public var checks: [[Double]]?
    /// The app's verdict on `checks` against the stated equation; nil when there was nothing to check.
    public var verification: ChartVerification?
    /// The numeric tick labels printed along each axis, in order (x: left to right; y: top to bottom), so the app
    /// can pair them with the tick marks it finds in the pixels (`GraphReader`).
    public var xTicks: [Double]?
    public var yTicks: [Double]?
    /// Slope fields: every initial condition the question offers (each part's or choice's), tested by the app
    /// against the drawn curve.
    public var candidates: [ChartCandidate]?
    /// The labels the original prints along each axis (read from the picture); drawn instead of evenly spaced
    /// numbers. An empty list means the original prints none on that axis; nil means unknown.
    public var xAxisLabels: [ChartTick]?
    public var yAxisLabels: [ChartTick]?
    /// The field's arrows as the picture draws them, `[x, y, m]`, and whether they are drawn instead of the
    /// stated slope (it did not match the picture, or could not be evaluated).
    public var fieldSamples: [[Double]]?
    public var fieldFromPicture: Bool?
    /// `chartType` "phaseLine": the phase line as the picture draws it.
    public var phaseLine: PhaseLine?
    /// Solution sketches without a field: the right-hand side of `dy/dx = f(x, y)` the drawn curves solve (from the
    /// question, possibly with a fitted time scale). Series with `through` are integrated with it (`CurveFitter`).
    public var odeSlope: String?
    /// false: a diagram drawn without axes, grid or numbers (vectors in the plane, a triangle of vectors); the
    /// series' coordinates are in any consistent units.
    public var showAxes: Bool?
    /// The axis runs the other way (depth increasing downward, as in a lake's temperature profile).
    public var yReversed: Bool?
    public var xReversed: Bool?
    /// The plot area itself is tinted in the original (a filled panel behind data curves), not a region.
    public var tintedPlot: Bool?
    /// Text printed inside the plot.
    public var annotations: [ChartAnnotation]?
    public var axesHidden: Bool { showAxes == false }
    /// Every curve in the original is one colour: the redraw uses one colour too (set from the picture).
    public var monochrome: Bool?
    /// The picture holds several plots side by side (maps I and II): each is its own chart, left to right, drawn
    /// side by side. The outer chart's own series are then ignored.
    public var panels: [StandardChart]?
    /// A panel's label as the original prints it ("I", "II", "Figure A").
    public var title: String?
    /// Shapes the question offers for this picture (each parametric pair, each f(x, y) of a matching question):
    /// the app draws each against the picture and keeps the one that fits (`ShapeFitter`).
    public var shapeCandidates: [ChartSeries]?

    public var hasPanels: Bool { (panels?.count ?? 0) >= 2 }

    /// Every curve is a trace of the picture (points, no formula, no recognised family): a redraw can only
    /// approximate the original, so the original image is shown instead.
    public var isOnlyTraced: Bool {
        guard !isSlopeField, !isPhaseLine, !hasPanels, !series.isEmpty else { return false }
        // Followed curve by curve from the pixels and confirmed against the picture: as faithful as the original.
        if verification?.passed == true, verification?.summary.hasPrefix("Traced from the picture") == true { return false }
        return series.allSatisfy { s in
            (s.latex ?? "").isEmpty && s.xt == nil && [.curve].contains(s.seriesKind) && (s.points?.count ?? 0) >= 2
        } && (provenance == StandardChart.traced || verification?.summary.contains("raced from the pi") == true)
    }

    public var isPhaseLine: Bool { chartType == "phaseLine" && phaseLine != nil }

    public var isSlopeField: Bool { chartType == "slopeField" }
    public var isStated: Bool { provenance == Self.stated }
    public var isTraced: Bool { provenance == Self.traced }

    public init(
        chartType: String,
        xLabel: String? = nil,
        yLabel: String? = nil,
        series: [ChartSeries] = [],
        xRange: [Double]? = nil,
        yRange: [Double]? = nil,
        confidence: Double = 0,
        slope: String? = nil,
        arrows: Bool = true,
        xStep: Double? = nil,
        yStep: Double? = nil,
        fieldColumns: Int? = nil,
        fieldRows: Int? = nil,
        notes: String? = nil,
        provenance: String? = nil,
        definition: String? = nil,
        checks: [[Double]]? = nil,
        verification: ChartVerification? = nil,
        xTicks: [Double]? = nil,
        yTicks: [Double]? = nil,
        candidates: [ChartCandidate]? = nil
    ) {
        self.chartType = chartType
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.series = series
        self.xRange = xRange
        self.yRange = yRange
        self.confidence = Self.clampedConfidence(confidence)
        self.slope = slope
        self.arrows = arrows
        self.xStep = xStep
        self.yStep = yStep
        self.fieldColumns = fieldColumns
        self.fieldRows = fieldRows
        self.notes = notes
        self.provenance = provenance
        self.definition = definition
        self.checks = checks
        self.verification = verification
        self.xTicks = xTicks
        self.yTicks = yTicks
        self.candidates = candidates
    }

    /// Confidence is 0–1; anything else the model (or a stored row) reports is clamped so it can be shown safely.
    public static func clampedConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, value))
    }

    private enum CodingKeys: String, CodingKey {
        case chartType, xLabel, yLabel, series, xRange, yRange, confidence, slope, arrows, xStep, yStep, fieldColumns, fieldRows, notes
        case provenance, definition, checks, verification, xTicks, yTicks, candidates
        case xAxisLabels, yAxisLabels, fieldSamples, fieldFromPicture, phaseLine, odeSlope
        case monochrome, panels, title, shapeCandidates
        case showAxes, yReversed, xReversed, tintedPlot, annotations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartType = try c.decodeIfPresent(String.self, forKey: .chartType) ?? "line"
        xLabel = try c.decodeIfPresent(String.self, forKey: .xLabel)
        yLabel = try c.decodeIfPresent(String.self, forKey: .yLabel)
        series = try c.decodeIfPresent([ChartSeries].self, forKey: .series) ?? []
        xRange = try c.decodeIfPresent([Double].self, forKey: .xRange)
        yRange = try c.decodeIfPresent([Double].self, forKey: .yRange)
        confidence = Self.clampedConfidence(try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0)
        slope = try c.decodeIfPresent(String.self, forKey: .slope)
        arrows = try c.decodeIfPresent(Bool.self, forKey: .arrows) ?? true
        xStep = try c.decodeIfPresent(Double.self, forKey: .xStep)
        yStep = try c.decodeIfPresent(Double.self, forKey: .yStep)
        fieldColumns = try c.decodeIfPresent(Int.self, forKey: .fieldColumns)
        fieldRows = try c.decodeIfPresent(Int.self, forKey: .fieldRows)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        provenance = try c.decodeIfPresent(String.self, forKey: .provenance)
        definition = try c.decodeIfPresent(String.self, forKey: .definition)
        checks = try c.decodeIfPresent([[Double]].self, forKey: .checks)
        verification = try c.decodeIfPresent(ChartVerification.self, forKey: .verification)
        xTicks = try c.decodeIfPresent([Double].self, forKey: .xTicks)
        yTicks = try c.decodeIfPresent([Double].self, forKey: .yTicks)
        candidates = try c.decodeIfPresent([ChartCandidate].self, forKey: .candidates)
        xAxisLabels = try c.decodeIfPresent([ChartTick].self, forKey: .xAxisLabels)
        yAxisLabels = try c.decodeIfPresent([ChartTick].self, forKey: .yAxisLabels)
        fieldSamples = try c.decodeIfPresent([[Double]].self, forKey: .fieldSamples)
        fieldFromPicture = try c.decodeIfPresent(Bool.self, forKey: .fieldFromPicture)
        phaseLine = try c.decodeIfPresent(PhaseLine.self, forKey: .phaseLine)
        odeSlope = try c.decodeIfPresent(String.self, forKey: .odeSlope)
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome)
        panels = try? c.decodeIfPresent([StandardChart].self, forKey: .panels)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        shapeCandidates = try? c.decodeIfPresent([ChartSeries].self, forKey: .shapeCandidates)
        showAxes = try c.decodeIfPresent(Bool.self, forKey: .showAxes)
        yReversed = try c.decodeIfPresent(Bool.self, forKey: .yReversed)
        xReversed = try c.decodeIfPresent(Bool.self, forKey: .xReversed)
        tintedPlot = try c.decodeIfPresent(Bool.self, forKey: .tintedPlot)
        annotations = try? c.decodeIfPresent([ChartAnnotation].self, forKey: .annotations)
    }
}

/// An image extracted from a document. The original PNG lives under `AppPaths.figures/<originalPath>`.
public struct Figure: Codable, Identifiable, Sendable, Equatable {
    public var id: FigureID
    /// The document it was clipped from; nil once that document was removed while the questions using the
    /// figure were kept.
    public var documentId: DocumentID?
    public var pageOrIndex: Int
    /// PNG under `AppPaths.figures`.
    public var originalPath: String
    public var kind: FigureKind
    /// Filled by the FigureAgent for charts.
    public var chart: StandardChart?
    public var status: FigureStatus
    public var caption: String?

    public init(
        id: FigureID = .new(),
        documentId: DocumentID?,
        pageOrIndex: Int,
        originalPath: String,
        kind: FigureKind = .unknown,
        chart: StandardChart? = nil,
        status: FigureStatus = .pending,
        caption: String? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.pageOrIndex = pageOrIndex
        self.originalPath = originalPath
        self.kind = kind
        self.chart = chart
        self.status = status
        self.caption = caption
    }

    /// Charts at or above this confidence (the picture check's verdict) are accepted without review.
    public static let autoAcceptConfidence = 0.75

    /// Accepts a figure awaiting review whose chart is confident enough and did not fail its check. Decisions
    /// already made (accepted, kept original, skipped) are left alone. Returns whether it was accepted.
    @discardableResult
    public mutating func acceptIfConfident() -> Bool {
        // A trace of the picture is never as faithful as the picture: keep the original.
        if status == .pending || status == .reviewing || status == .accepted, kind == .chart, chart?.isOnlyTraced == true {
            status = .keptOriginal
            return false
        }
        guard status == .pending || status == .reviewing, kind == .chart, let chart,
              chart.confidence >= Self.autoAcceptConfidence, chart.verification?.passed != false else { return false }
        status = .accepted
        return true
    }
}
