import Foundation
import ThubanCore

/// Turns a `StandardChart` into the Desmos rows both graph panes draw: functions as `y = f(x)`, tabulated series
/// as smooth curves (scatter as dots, bars as bars), and a slope / direction field with its solution curves.
enum ChartRenderer {
    /// Grid density of a rendered direction field.
    static let fieldColumns = 20
    static let fieldRows = 16

    /// The rows for a chart. Solution curves given as an initial condition are integrated through `engine`
    /// (RK4 over the chart's x-range); without an engine they are left out.
    static func expressions(for chart: StandardChart, theme: ResolvedTheme, engine: MathEngine? = nil) async -> [GraphExpression] {
        let palette = [theme.accent, theme.signal, theme.neg, theme.pos, theme.accentDeep]
        var out: [GraphExpression] = []
        let viewport = viewport(for: chart) ?? GraphViewport(xmin: -5, xmax: 5, ymin: -5, ymax: 5)
        let slope = chart.isSlopeField ? chart.slope?.nilIfEmpty : nil

        if let slope {
            let rows = ChartGeometry.slopeFieldRows(
                idPrefix: "f", slope: slope,
                xRange: viewport.xmin...viewport.xmax, yRange: viewport.ymin...viewport.ymax,
                columns: fieldColumns, rows: fieldRows, arrows: chart.arrows
            )
            out += rows.map { expression(from: $0, color: theme.inkDim) }
        }

        for (offset, series) in chart.series.enumerated() {
            let color = series.color?.nilIfEmpty ?? palette[offset % palette.count]
            let id = "series-\(offset)"
            var row = row(id: id, series: series, chart: chart)
            if row == nil, let slope, let engine, let start = series.throughPoint {
                let points = (try? await engine.integrateSlope(slope, through: start, xRange: viewport.xmin...viewport.xmax)) ?? []
                let clipped = clip(points, ymin: viewport.ymin, ymax: viewport.ymax)
                row = ChartGeometry.polylineRow(id: id, points: clipped)
            }
            guard let row else { continue }
            out.append(expression(from: row, color: color))
        }
        return out
    }

    /// Keeps the run of points around the initial condition that stays within a generous margin of the y-range,
    /// so a blow-up does not drag the curve (and Desmos) off to ±10⁶.
    private static func clip(_ points: [[Double]], ymin: Double, ymax: Double) -> [[Double]] {
        let margin = (ymax - ymin) * 1.5
        return points.filter { $0.count >= 2 && $0[1] >= ymin - margin && $0[1] <= ymax + margin }
    }

    /// One row per series: `latex` wins; otherwise the points, drawn by the chart's type.
    private static func row(id: String, series: ChartSeries, chart: StandardChart) -> ChartGeometry.Row? {
        if let latex = series.latex?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty {
            return ChartGeometry.functionRow(id: id, latex: latex)
        }
        let points = (series.points ?? []).filter { $0.count >= 2 }
        guard !points.isEmpty else { return nil }
        switch chart.chartType {
        case "scatter":
            return ChartGeometry.pointsRow(id: id, points: points)
        case "bar", "histogram":
            return ChartGeometry.barsRow(id: id, points: points)
        default:
            if points.count == 1 { return ChartGeometry.pointsRow(id: id, points: points) }
            return ChartGeometry.polylineRow(id: id, points: ChartGeometry.smoothed(points))
        }
    }

    private static func expression(from row: ChartGeometry.Row, color: String) -> GraphExpression {
        var expression = GraphExpression(id: row.id, latex: row.latex, color: color, hidden: row.hidden)
        expression.fillOpacity = row.fillOpacity
        if let domain = row.parametricDomain {
            expression.parametricDomain = GraphExpression.Domain(min: domain.lowerBound, max: domain.upperBound)
        }
        expression.showsPoints = row.showsPoints
        expression.lineWidth = row.lineWidth
        return expression
    }

    /// The agent's ranges when present, otherwise the point extent with 10 % padding.
    static func viewport(for chart: StandardChart) -> GraphViewport? {
        if let x = chart.xRange, let y = chart.yRange, x.count == 2, y.count == 2, x[0] < x[1], y[0] < y[1] {
            return GraphViewport(xmin: x[0], xmax: x[1], ymin: y[0], ymax: y[1])
        }
        let points = chart.series.flatMap { $0.points ?? [] }.filter { $0.count >= 2 }
        guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max()
        else { return nil }
        let padX = max((maxX - minX) * 0.1, 1)
        let padY = max((maxY - minY) * 0.1, 1)
        return GraphViewport(xmin: minX - padX, xmax: maxX + padX, ymin: min(0, minY) - padY, ymax: maxY + padY)
    }
}
