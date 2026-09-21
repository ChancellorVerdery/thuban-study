import Foundation

public enum FigureKind: String, Codable, Sendable, CaseIterable {
    case chart, diagram, photo, table, unknown
}

public enum FigureStatus: String, Codable, Sendable, CaseIterable {
    case pending, reviewing, accepted, keptOriginal, skipped
}

/// One series of a `StandardChart`: either a table of `[x, y]` points or a LaTeX function of x.
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

/// Standardized chart: everything needed to redraw the figure in the app's own graph style (Desmos expressions or
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
        verification: ChartVerification? = nil
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
    }

    /// Confidence is 0–1; anything else the model (or a stored row) reports is clamped so it can be shown safely.
    public static func clampedConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, value))
    }

    private enum CodingKeys: String, CodingKey {
        case chartType, xLabel, yLabel, series, xRange, yRange, confidence, slope, arrows, xStep, yStep, fieldColumns, fieldRows, notes
        case provenance, definition, checks, verification
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
}
