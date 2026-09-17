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

    public init(name: String, points: [[Double]]? = nil, latex: String? = nil, color: String? = nil) {
        self.name = name
        self.points = points
        self.latex = latex
        self.color = color
    }
}

/// Standardized chart: everything needed to redraw the figure in the app's own graph style (Desmos expressions or
/// a table of series). This is the "one graph style across the app" representation.
public struct StandardChart: Codable, Sendable, Equatable {
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

    public var isSlopeField: Bool { chartType == "slopeField" }

    public init(
        chartType: String,
        xLabel: String? = nil,
        yLabel: String? = nil,
        series: [ChartSeries] = [],
        xRange: [Double]? = nil,
        yRange: [Double]? = nil,
        confidence: Double = 0,
        slope: String? = nil,
        arrows: Bool = true
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
    }

    /// Confidence is 0–1; anything else the model (or a stored row) reports is clamped so it can be shown safely.
    public static func clampedConfidence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(1, Swift.max(0, value))
    }

    private enum CodingKeys: String, CodingKey { case chartType, xLabel, yLabel, series, xRange, yRange, confidence, slope, arrows }

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
