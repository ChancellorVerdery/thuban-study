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
    /// "line" | "scatter" | "bar" | "function" | "histogram"
    public var chartType: String
    public var xLabel: String?
    public var yLabel: String?
    public var series: [ChartSeries]
    public var xRange: [Double]?
    public var yRange: [Double]?
    /// 0–1 from the agent.
    public var confidence: Double

    public init(
        chartType: String,
        xLabel: String? = nil,
        yLabel: String? = nil,
        series: [ChartSeries] = [],
        xRange: [Double]? = nil,
        yRange: [Double]? = nil,
        confidence: Double = 0
    ) {
        self.chartType = chartType
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.series = series
        self.xRange = xRange
        self.yRange = yRange
        self.confidence = confidence
    }

    private enum CodingKeys: String, CodingKey { case chartType, xLabel, yLabel, series, xRange, yRange, confidence }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartType = try c.decodeIfPresent(String.self, forKey: .chartType) ?? "line"
        xLabel = try c.decodeIfPresent(String.self, forKey: .xLabel)
        yLabel = try c.decodeIfPresent(String.self, forKey: .yLabel)
        series = try c.decodeIfPresent([ChartSeries].self, forKey: .series) ?? []
        xRange = try c.decodeIfPresent([Double].self, forKey: .xRange)
        yRange = try c.decodeIfPresent([Double].self, forKey: .yRange)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
    }
}

/// An image extracted from a document. The original PNG lives under `AppPaths.figures/<originalPath>`.
public struct Figure: Codable, Identifiable, Sendable, Equatable {
    public var id: FigureID
    public var documentId: DocumentID
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
        documentId: DocumentID,
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
