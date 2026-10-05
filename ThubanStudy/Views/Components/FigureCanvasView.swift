import SwiftUI
import ThubanCore

/// A `StandardChart` drawn natively (no web view, no network): the geometry comes from `FigureScene`, and this
/// view maps it into its own frame and strokes it in the theme's colours — grid and axes in ink, the slope field
/// in the signal colour, curves in the accent palette (never the field's colour).
struct FigureCanvasView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.thubanTheme) private var theme
    var chart: StandardChart
    @State private var scene: FigureScene?

    var body: some View {
        ZStack {
            theme.panelColor
            if chart.hasPanels, let panels = chart.panels {
                HStack(spacing: 8) {
                    ForEach(panels.indices, id: \.self) { k in
                        ZStack(alignment: .topLeading) {
                            AnyView(FigureCanvasView(chart: panels[k]))
                            if let title = panels[k].title, !title.isEmpty {
                                Text(title).font(.system(size: 13, weight: .semibold, design: .serif)).foregroundStyle(Color(hex: theme.ink))
                                    .padding(6)
                            }
                        }
                    }
                }
                .padding(6)
            } else if let phase = chart.phaseLine, chart.isPhaseLine {
                let zoom = AppZoom.shared.scale
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    PhaseLineRenderer(phase: phase, theme: theme, zoom: zoom).draw(in: &context, size: size)
                }
            } else if let scene = FigureCache.cachedScene(for: chart) ?? scene {
                let zoom = AppZoom.shared.scale
                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    FigureCanvasRenderer(scene: scene, theme: theme, zoom: zoom).draw(in: &context, size: size)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ThubanMetrics.controlRadius, style: .continuous).stroke(theme.lineColor, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
        .task(id: chart) {
            guard !chart.hasPanels else { return }
            // Keep the previous drawing on screen until the new one is ready (no flash between figures).
            let built = await FigureCache.scene(for: chart, engine: app.engine)
            guard !Task.isCancelled else { return }
            scene = built
        }
    }

    private var accessibilityText: String {
        // Series names and the equation describe what the figure shows: spoken only when descriptions are on.
        guard app.showFigureDescriptions else { return chart.isSlopeField ? "Direction field" : "Graph" }
        var parts: [String] = [chart.isSlopeField ? "Direction field" : "Graph"]
        if let slope = chart.slope, chart.isSlopeField { parts.append("dy/dx = \(slope)") }
        parts += chart.series.map(\.name).filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}

/// Draws a `FigureScene` into a `GraphicsContext`.
struct FigureCanvasRenderer {
    var scene: FigureScene
    var theme: ResolvedTheme
    /// The app zoom (`AppZoom`): label sizes are design points at 100 %.
    var zoom: CGFloat = 1

    private var labelFont: Font { Font.system(size: 10 * zoom, weight: .regular, design: .default).monospacedDigit() }
    private var axisNameFont: Font { Font.system(size: 13 * zoom, weight: .regular, design: .serif).italic() }

    /// Text printed in the plot: a name ("a", "AB", "r′") in serif italic like the original's, anything longer
    /// ("|u| = 2", "60°") upright.
    private func nameFont(_ text: String) -> Font {
        let isName = text.count <= 3 && text.first?.isLetter == true && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "′" || $0 == "'" }
        return isName ? Font.system(size: 13 * zoom, design: .serif).italic() : Font.system(size: 12 * zoom)
    }

    /// A diagram's window widened along its shorter side to the frame's proportions, so one unit is as long
    /// across as up and a square stays square.
    static func equalScale(_ window: FigureScene.Window, size: CGSize) -> FigureScene.Window {
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let unit = max(xSpan / Double(size.width), ySpan / Double(size.height))
        let xPad = (unit * Double(size.width) - xSpan) / 2, yPad = (unit * Double(size.height) - ySpan) / 2
        return FigureScene.Window(x: (window.x.lowerBound - xPad)...(window.x.upperBound + xPad),
                                  y: (window.y.lowerBound - yPad)...(window.y.upperBound + yPad))
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 20, size.height > 20 else { return }
        let window = scene.showAxes ? scene.window : Self.equalScale(scene.window, size: size)
        let xSpan = window.x.upperBound - window.x.lowerBound, ySpan = window.y.upperBound - window.y.lowerBound
        let sx = size.width / xSpan, sy = size.height / ySpan
        // Pixels per unit along each axis, signed: right and up unless the axis is reversed.
        let xDir: CGFloat = scene.xReversed ? -1 : 1, yDir: CGFloat = scene.yReversed ? 1 : -1
        func px(_ x: Double) -> CGFloat {
            let along = CGFloat((x - window.x.lowerBound) * sx)
            return scene.xReversed ? size.width - along : along
        }
        func py(_ y: Double) -> CGFloat {
            let along = CGFloat((y - window.y.lowerBound) * sy)
            return scene.yReversed ? along : size.height - along
        }
        func point(_ p: [Double]) -> CGPoint { CGPoint(x: px(p[0]), y: py(p[1])) }

        let ink = Color(hex: theme.ink)
        let line = Color(hex: theme.line)
        let dim = Color(hex: theme.inkDim)
        // Nothing is drawn outside the plot (a curve leaving the window stops at its edge).
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        if scene.tintedPlot { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: theme.accentTint))) }

        let xAxisY = min(max(py(0), 0), size.height), yAxisX = min(max(px(0), 0), size.width)
        if scene.showAxes {
            // Grid: minor at half steps, major at the tick spacing.
            var minor = Path(), major = Path()
            for x in FigureScene.ticks(in: window.x, step: scene.xStep / 2) {
                let isMajor = abs((x / scene.xStep).rounded() * scene.xStep - x) < scene.xStep * 1e-6
                var path = isMajor ? major : minor
                path.move(to: CGPoint(x: px(x), y: 0)); path.addLine(to: CGPoint(x: px(x), y: size.height))
                if isMajor { major = path } else { minor = path }
            }
            for y in FigureScene.ticks(in: window.y, step: scene.yStep / 2) {
                let isMajor = abs((y / scene.yStep).rounded() * scene.yStep - y) < scene.yStep * 1e-6
                var path = isMajor ? major : minor
                path.move(to: CGPoint(x: 0, y: py(y))); path.addLine(to: CGPoint(x: size.width, y: py(y)))
                if isMajor { major = path } else { minor = path }
            }
            context.stroke(minor, with: .color(line.opacity(0.35)), lineWidth: 0.5)
            context.stroke(major, with: .color(line.opacity(0.9)), lineWidth: 0.75)

            // Axes through the origin when it is in view; labels ride the axis or the nearest edge.
            var axes = Path()
            if window.y.contains(0) { axes.move(to: CGPoint(x: 0, y: py(0))); axes.addLine(to: CGPoint(x: size.width, y: py(0))) }
            if window.x.contains(0) { axes.move(to: CGPoint(x: px(0), y: 0)); axes.addLine(to: CGPoint(x: px(0), y: size.height)) }
            context.stroke(axes, with: .color(ink), lineWidth: 1.8)
        }

        // The field under the curves.
        if scene.hasField {
            let field = Color(hex: theme.signal).opacity(0.85)
            let cell = min(size.width / CGFloat(scene.fieldColumns), size.height / CGFloat(scene.fieldRows))
            let standardHalf = cell * 0.4
            var segments = Path(), heads = Path()
            for arrow in scene.arrows {
                guard let m = arrow.slope else { continue }
                // Direction (1, m) in data space, taken to pixels and normalised.
                var dx = CGFloat(sx) * xDir, dy = CGFloat(sy * m) * yDir
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0, length.isFinite else { continue }
                dx /= length; dy /= length
                let c = CGPoint(x: px(arrow.x), y: py(arrow.y))
                let half = scene.variesInLength ? cell * 0.5 * CGFloat(min(1, max(0.2, arrow.length ?? 0.8))) : standardHalf
                let tail = CGPoint(x: c.x - dx * half, y: c.y - dy * half), tip = CGPoint(x: c.x + dx * half, y: c.y + dy * half)
                segments.move(to: tail); segments.addLine(to: tip)
                if scene.arrowheads {
                    // A head a draughtsman would draw: 45 % of the half-length long, as wide as it is long, never
                    // smaller than a few pixels so it stays readable in a dense field.
                    let headLength = max(6, half * 0.55)
                    let base = CGPoint(x: tip.x - dx * headLength, y: tip.y - dy * headLength)
                    let w = max(3.6, headLength * 0.5)
                    heads.move(to: tip)
                    heads.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    heads.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    heads.closeSubpath()
                }
            }
            context.stroke(segments, with: .color(field), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))
            context.fill(heads, with: .color(field))
        }

        // Curves, dots and bars, each in the colour of its role (`FigureScene.Mark.paletteIndex`, `inInk`).
        let palette: [String] = scene.hasField
            ? [theme.accent, theme.neg, theme.pos, theme.accentDeep]
            : [theme.accent, theme.signal, theme.neg, theme.pos, theme.accentDeep]
        func colour(of mark: FigureScene.Mark) -> Color {
            if let hex = mark.color { return Color(hex: hex) }
            return mark.inInk ? ink : Color(hex: palette[mark.paletteIndex % palette.count])
        }
        // Shaded regions first, translucent, so every curve and axis stays visible through them.
        for mark in scene.marks where mark.kind == .fill {
            var path = Path()
            for rect in mark.pieces where rect.count == 2 {
                let a = point(rect[0]), b = point(rect[1])
                // Rows overlap by a hair so no seam shows between them.
                path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y) - 0.25, width: abs(b.x - a.x), height: abs(b.y - a.y) + 0.5))
            }
            context.fill(path, with: .color(colour(of: mark).opacity(0.28)))
        }
        // Names beside the marks, drawn after all of them so no later curve covers one.
        var names: [(text: String, at: CGPoint, anchor: UnitPoint)] = []
        for mark in scene.marks where mark.kind != .fill {
            let color = colour(of: mark)
            switch mark.kind {
            case .fill:
                break
            case .vector:
                // A straight arrow from its tail to its head.
                for piece in mark.pieces where piece.count >= 2 {
                    let a = point(piece[0]), b = point(piece[1])
                    var dx = b.x - a.x, dy = b.y - a.y
                    let length = (dx * dx + dy * dy).squareRoot()
                    guard length > 1 else { continue }
                    dx /= length; dy /= length
                    let headLength = min(16, length * 0.4), w = headLength * 0.45
                    let base = CGPoint(x: b.x - dx * headLength, y: b.y - dy * headLength)
                    var shaft = Path()
                    shaft.move(to: a); shaft.addLine(to: base)
                    context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    var head = Path()
                    head.move(to: b)
                    head.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    head.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    head.closeSubpath()
                    context.fill(head, with: .color(color))
                    strokeTicks(mark.ticks, from: a, to: b, color: color, in: &context)
                    if let text = mark.label { names.append(Self.besideMiddle(text, from: a, to: b)) }
                }
            case .arrows:
                // Filled heads on the curve, pointing the way the parameter runs.
                var heads = Path()
                for a in mark.pieces.flatMap({ $0 }) where a.count >= 4 {
                    var dx = CGFloat(a[2] * sx) * xDir, dy = CGFloat(a[3] * sy) * yDir
                    let length = (dx * dx + dy * dy).squareRoot()
                    guard length > 0, length.isFinite else { continue }
                    dx /= length; dy /= length
                    let c = point(a)
                    let headLength: CGFloat = 15, w: CGFloat = 7
                    let tip = CGPoint(x: c.x + dx * headLength / 2, y: c.y + dy * headLength / 2)
                    let base = CGPoint(x: c.x - dx * headLength / 2, y: c.y - dy * headLength / 2)
                    heads.move(to: tip)
                    heads.addLine(to: CGPoint(x: base.x - dy * w, y: base.y + dx * w))
                    heads.addLine(to: CGPoint(x: base.x + dy * w, y: base.y - dx * w))
                    heads.closeSubpath()
                }
                context.fill(heads, with: .color(color))
            case .line:
                var path = Path()
                for piece in mark.pieces where piece.count >= 2 {
                    path.move(to: point(piece[0]))
                    for p in piece.dropFirst() { path.addLine(to: point(p)) }
                }
                let dash: [CGFloat] = mark.style == .dashed ? [12, 7.5] : mark.style == .dotted ? [2.25, 6] : []
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3.75, lineCap: .round, lineJoin: .round, dash: dash))
                if mark.isSegment, let piece = mark.pieces.first, piece.count >= 2 {
                    // The middle stretch of the polyline carries the ticks and the name.
                    let k = (piece.count - 2) / 2
                    let a = point(piece[k]), b = point(piece[k + 1])
                    strokeTicks(mark.ticks, from: a, to: b, color: color, in: &context)
                    if let text = mark.label { names.append(Self.besideMiddle(text, from: a, to: b)) }
                } else if let text = mark.label,
                          let end = mark.pieces.flatMap({ $0 }).last(where: { window.x.contains($0[0]) && window.y.contains($0[1]) }) {
                    // A curve is named at its last visible point, on the side with room.
                    let c = point(end), right = c.x < size.width - 40
                    names.append((text, CGPoint(x: c.x + (right ? 7 : -7), y: max(c.y - 7, 14)), right ? .bottomLeading : .bottomTrailing))
                }
            case .angle:
                guard mark.pieces.count == 3, let v = mark.pieces[0].first, let p1 = mark.pieces[1].first, let p2 = mark.pieces[2].first else { break }
                if let name = strokeAngle(at: point(v), point(p1), point(p2), right: mark.rightAngle, span: min(size.width, size.height),
                                          color: color, in: &context), let text = mark.label {
                    names.append((text, name, .center))
                }
            case .dots:
                for (k, p) in mark.pieces.flatMap({ $0 }).enumerated() {
                    let c = point(p)
                    context.fill(Path(ellipseIn: CGRect(x: c.x - 5.25, y: c.y - 5.25, width: 10.5, height: 10.5)), with: .color(color))
                    if let text = mark.labels?[safe: k], !text.isEmpty {
                        // Beside the dot, on the side with room.
                        let right = c.x < size.width - 60
                        context.draw(Text(text).font(Font.system(size: 12 * zoom, design: .serif).italic()).foregroundColor(ink),
                                     at: CGPoint(x: c.x + (right ? 9 : -9), y: c.y - 9), anchor: right ? .bottomLeading : .bottomTrailing)
                    }
                }
            case .bars:
                for p in mark.pieces.flatMap({ $0 }) {
                    let left = min(px(p[0] - 0.4), px(p[0] + 0.4)), right = max(px(p[0] - 0.4), px(p[0] + 0.4))
                    let top = min(py(p[1]), py(0)), bottom = max(py(p[1]), py(0))
                    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                    context.fill(Path(rect), with: .color(color.opacity(0.55)))
                    context.stroke(Path(rect), with: .color(color), lineWidth: 1.5)
                }
            }
        }
        for name in names {
            context.draw(Text(name.text).font(nameFont(name.text)).foregroundColor(ink), at: name.at, anchor: name.anchor)
        }
        // The original's own text inside the plot, at its data position.
        for note in scene.annotations {
            context.draw(Text(note.text).font(nameFont(note.text)).foregroundColor(ink), at: CGPoint(x: px(note.x), y: py(note.y)), anchor: .center)
        }
        guard scene.showAxes else { return }

        // Tick labels, plain like the original's, over the curves so none is hidden.
        func label(_ text: String, at position: CGPoint, anchor: UnitPoint) {
            // Symbols ("c") are set in italic like the original's; numbers in the label font.
            let symbolic = text.count == 1 && text.first!.isLetter
            let font = symbolic ? Font.system(size: 12 * zoom, design: .serif).italic() : labelFont
            context.draw(Text(text).font(font).foregroundColor(dim), at: position, anchor: anchor)
        }
        let xLabelY = min(xAxisY + 3, size.height - 13)
        let xTicks: [ChartTick] = scene.xTickLabels ?? FigureScene.ticks(in: window.x, step: scene.xStep)
            .filter { abs($0) > scene.xStep * 1e-6 }.map { ChartTick(value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) }
        var lastX = -CGFloat.infinity
        let xSlack = (window.x.upperBound - window.x.lowerBound) * 0.02, ySlack = (window.y.upperBound - window.y.lowerBound) * 0.02
        // Left to right on screen (a reversed axis runs its values the other way).
        for tick in xTicks.sorted(by: { px($0.value) < px($1.value) }) where tick.value >= window.x.lowerBound - xSlack && tick.value <= window.x.upperBound + xSlack {
            // A label at the very edge is kept, nudged inside the frame; crowded labels are thinned.
            let at = min(max(px(tick.value), 10), size.width - 10)
            guard at - lastX >= 26 else { continue }
            lastX = at
            label(tick.text, at: CGPoint(x: at, y: xLabelY), anchor: .top)
        }
        // Too little room left of the axis for a number ("0.8" would be cut to ".8"): numbers go on its right.
        let yLabelsRight = yAxisX < 34
        let yLabelX = yLabelsRight ? yAxisX + 5 : yAxisX - 4
        let yTicks: [ChartTick] = scene.yTickLabels ?? FigureScene.ticks(in: window.y, step: scene.yStep)
            .filter { abs($0) > scene.yStep * 1e-6 }.map { ChartTick(value: $0, text: ChartGeometry.number($0).replacingOccurrences(of: "-", with: "−")) }
        var lastY = CGFloat.infinity
        // Bottom to top on screen.
        for tick in yTicks.sorted(by: { py($0.value) > py($1.value) }) where tick.value >= window.y.lowerBound - ySlack && tick.value <= window.y.upperBound + ySlack {
            let at = min(max(py(tick.value), 8), size.height - 8)
            guard lastY - at >= 14 else { continue }
            // On the right of the axis the top number would run into the axis name.
            if yLabelsRight, at < 26 { continue }
            lastY = at
            let text = tick.text
            label(text, at: CGPoint(x: yLabelX, y: at), anchor: yLabelsRight ? .leading : .trailing)
        }
        if scene.xTickLabels == nil, scene.yTickLabels == nil, window.x.contains(0), window.y.contains(0) {
            label("0", at: CGPoint(x: px(0) - 4, y: py(0) + 3), anchor: .topTrailing)
        }

        // Axis names at the ends of the axes, on whichever side has room.
        let xName = scene.xLabel ?? "x", yName = scene.yLabel ?? "y"
        let xNameY = xAxisY < 26 ? min(xAxisY + 12, size.height - 10) : xAxisY - 12
        context.draw(Text(xName).font(axisNameFont).foregroundColor(ink), at: CGPoint(x: size.width - 6, y: xNameY), anchor: .trailing)
        let yNameLeft = yAxisX > size.width - 26
        context.draw(Text(yName).font(axisNameFont).foregroundColor(ink),
                     at: CGPoint(x: yNameLeft ? yAxisX - 8 : min(yAxisX + 8, size.width - 12), y: xAxisY < 26 ? 30 : 10),
                     anchor: yNameLeft ? .trailing : .leading)
    }

    /// Where a straight mark's name goes: beside its middle, off to its left (as a vector's name is printed).
    private static func besideMiddle(_ text: String, from a: CGPoint, to b: CGPoint) -> (text: String, at: CGPoint, anchor: UnitPoint) {
        let dx = b.x - a.x, dy = b.y - a.y, length = max((dx * dx + dy * dy).squareRoot(), 1)
        // The left normal on screen (y grows downwards).
        let nx = dy / length, ny = -dx / length, offset: CGFloat = 13
        return (text, CGPoint(x: (a.x + b.x) / 2 + nx * offset, y: (a.y + b.y) / 2 + ny * offset), .center)
    }

    /// `count` short marks across the middle of a→b, a few pixels apart (sides of equal length).
    private func strokeTicks(_ count: Int, from a: CGPoint, to b: CGPoint, color: Color, in context: inout GraphicsContext) {
        guard count > 0 else { return }
        let dx = b.x - a.x, dy = b.y - a.y, length = (dx * dx + dy * dy).squareRoot()
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length, half: CGFloat = 6, gap: CGFloat = 5
        var ticks = Path()
        for k in 0..<count {
            let along = (CGFloat(k) - CGFloat(count - 1) / 2) * gap
            let c = CGPoint(x: (a.x + b.x) / 2 + ux * along, y: (a.y + b.y) / 2 + uy * along)
            ticks.move(to: CGPoint(x: c.x - uy * half, y: c.y + ux * half))
            ticks.addLine(to: CGPoint(x: c.x + uy * half, y: c.y - ux * half))
        }
        context.stroke(ticks, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    /// An angle mark at `vertex` between the rays to `p1` and `p2`: an arc (or a right-angle box) about 7 % of the
    /// plot's smaller side across, kept inside the shorter ray. Returns where its name goes, on the bisector.
    private func strokeAngle(at vertex: CGPoint, _ p1: CGPoint, _ p2: CGPoint, right: Bool, span: CGFloat, color: Color,
                             in context: inout GraphicsContext) -> CGPoint? {
        let d1 = CGPoint(x: p1.x - vertex.x, y: p1.y - vertex.y), d2 = CGPoint(x: p2.x - vertex.x, y: p2.y - vertex.y)
        let l1 = (d1.x * d1.x + d1.y * d1.y).squareRoot(), l2 = (d2.x * d2.x + d2.y * d2.y).squareRoot()
        guard l1 > 2, l2 > 2 else { return nil }
        let u1 = CGPoint(x: d1.x / l1, y: d1.y / l1), u2 = CGPoint(x: d2.x / l2, y: d2.y / l2)
        let radius = min(max(span * 0.07, 10), min(l1, l2) * 0.45)
        var path = Path()
        if right {
            let s = radius * 0.75
            path.move(to: CGPoint(x: vertex.x + u1.x * s, y: vertex.y + u1.y * s))
            path.addLine(to: CGPoint(x: vertex.x + (u1.x + u2.x) * s, y: vertex.y + (u1.y + u2.y) * s))
            path.addLine(to: CGPoint(x: vertex.x + u2.x * s, y: vertex.y + u2.y * s))
        } else {
            // The interior angle, swept the short way from the first ray to the second.
            let a1 = atan2(u1.y, u1.x)
            var sweep = atan2(u2.y, u2.x) - a1
            if sweep > .pi { sweep -= 2 * .pi } else if sweep < -.pi { sweep += 2 * .pi }
            for k in 0...24 {
                let theta = a1 + sweep * CGFloat(k) / 24
                let p = CGPoint(x: vertex.x + radius * cos(theta), y: vertex.y + radius * sin(theta))
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        // A straight angle has no bisector between its rays: the name goes off to the first ray's left.
        var bx = u1.x + u2.x, by = u1.y + u2.y
        let b = (bx * bx + by * by).squareRoot()
        if b < 1e-3 { bx = u1.y; by = -u1.x } else { bx /= b; by /= b }
        let reach = radius + 12
        return CGPoint(x: vertex.x + bx * reach, y: vertex.y + by * reach)
    }
}

/// Draws a phase line: the axis in ink at the original's position and extent, a tick and label at each marked
/// point, and a filled arrowhead on each stretch pointing the way solutions move.
struct PhaseLineRenderer {
    var phase: PhaseLine
    var theme: ResolvedTheme
    var zoom: CGFloat = 1

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let ink = Color(hex: theme.ink), dim = Color(hex: theme.inkDim), accent = Color(hex: theme.accent)
        let vertical = phase.vertical
        let length = vertical ? size.height : size.width
        let across = vertical ? size.width : size.height
        let a = CGFloat(phase.start) * length, b = CGFloat(phase.end) * length
        let offset = CGFloat(phase.offset) * across
        // Position along the line (fraction of the drawn line) to a point in the view.
        func point(_ t: Double, _ shift: CGFloat = 0) -> CGPoint {
            let along = a + CGFloat(t) * (b - a)
            return vertical ? CGPoint(x: offset + shift, y: along) : CGPoint(x: along, y: offset + shift)
        }
        var axis = Path()
        axis.move(to: point(0)); axis.addLine(to: point(1))
        context.stroke(axis, with: .color(ink), lineWidth: 1.8)

        let scale = min(across * 0.12, 16)
        for mark in phase.marks {
            var tick = Path()
            tick.move(to: point(mark.position, -scale * 0.45)); tick.addLine(to: point(mark.position, scale * 0.45))
            context.stroke(tick, with: .color(ink), lineWidth: 1.8)
            guard !mark.text.isEmpty else { continue }
            let symbolic = mark.text.count == 1 && mark.text.first!.isLetter
            let font = symbolic ? Font.system(size: 14 * zoom, design: .serif).italic() : Font.system(size: 12 * zoom).monospacedDigit()
            context.draw(Text(mark.text).font(font).foregroundColor(dim), at: point(mark.position, -scale * 0.9), anchor: vertical ? .trailing : .top)
        }
        for arrow in phase.arrows {
            // Up the screen (smaller y) is increasing on a vertical line; right is increasing on a horizontal one.
            let forward: CGFloat = vertical ? (arrow.increasing ? -1 : 1) : (arrow.increasing ? 1 : -1)
            let centre = point(arrow.position)
            let headLength = scale * 1.4, halfWidth = scale * 0.55
            var head = Path()
            if vertical {
                head.move(to: CGPoint(x: centre.x, y: centre.y + forward * headLength / 2))
                head.addLine(to: CGPoint(x: centre.x - halfWidth, y: centre.y - forward * headLength / 2))
                head.addLine(to: CGPoint(x: centre.x + halfWidth, y: centre.y - forward * headLength / 2))
            } else {
                head.move(to: CGPoint(x: centre.x + forward * headLength / 2, y: centre.y))
                head.addLine(to: CGPoint(x: centre.x - forward * headLength / 2, y: centre.y - halfWidth))
                head.addLine(to: CGPoint(x: centre.x - forward * headLength / 2, y: centre.y + halfWidth))
            }
            head.closeSubpath()
            context.fill(head, with: .color(accent))
        }
    }
}
