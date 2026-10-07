import Foundation

extension FigureWorkflow {
    /// Noted on a chart the reviewer has confirmed against its original, so a later pass need not ask again.
    public static let confirmedNote = "Checked side by side with the original."

    /// What one figure's review came to.
    public enum ReviewResult: String, Sendable {
        /// The redraw (as it was, or as corrected) matches the original: shown in place of it.
        case confirmed
        /// Still wrong after every round: the original is shown and the figure waits for review.
        case unresolved
        /// Not something the app can redraw (a photo, a 3D surface): the original stays.
        case notRedrawable
        /// Already confirmed earlier, or not a figure at all.
        case skipped
    }

    /// Each curve the picture draws, as up to 16 points in its own coordinates (only when its axes are numbered,
    /// so the coordinates are true ones), one line per curve.
    static func measuredCurves(png: Data, hints: StandardChart?) async -> String? {
        let base = hints ?? StandardChart(chartType: "function", series: [], confidence: 0)
        guard let picture = await ShapeVerifier.Picture(png: png, hints: base), picture.reading.isCalibratedFromLabels else { return nil }
        let curves = picture.curves.filter { $0.count >= 25 }.sorted { $0.count > $1.count }.prefix(12)
        guard !curves.isEmpty else { return nil }
        func number(_ v: Double) -> String { String(format: "%.2f", v) }
        let lines = curves.enumerated().map { k, curve -> String in
            let step = max(1, curve.count / 15)
            let points = Swift.stride(from: 0, to: curve.count, by: step).map { curve[$0] }
            let data = points.map { picture.reading.data(column: Double($0.0), row: Double($0.1)) }
            return "curve \(k + 1): " + data.map { "(\(number($0.x)), \(number($0.y)))" }.joined(separator: " ")
        }
        return lines.joined(separator: "\n")
    }

    /// Each figure's redraw is drawn (`render`), shown to the reviewer beside its original, corrected when the
    /// reviewer finds it wrong (the correction is drawn, checked against the picture and shown again, up to
    /// `rounds` times), and shown in place of the original only once the reviewer confirms it.
    public static func selfReview(
        document: ImportedDocument, store: Store, reviewer: FigureReviewer, engine: MathEngine,
        render: @escaping @Sendable (StandardChart, Data) async -> Data?,
        rounds: Int = 3, force: Bool = false, only: ((Figure) -> Bool)? = nil,
        report: (@Sendable (Figure, ReviewResult, [String]) -> Void)? = nil
    ) async throws -> [Outcome] {
        var outcomes: [Outcome] = []
        let questions = (try? await store.questions(in: document.classId, filter: QuestionFilter(documentIds: [document.id]))) ?? []
        for var figure in try await store.figures(for: document.id) where (only?(figure) ?? true) {
            guard figure.status != .skipped, figure.kind != .photo, figure.kind != .table,
                  let png = try? Data(contentsOf: AppPaths.figureURL(figure.originalPath)), !png.isEmpty else { continue }
            if !force, figure.status == .accepted, figure.chart?.notes?.contains(confirmedNote) == true {
                report?(figure, .skipped, []); continue
            }
            let text = questions.filter { $0.figureIds.contains(figure.id) }.map(questionText).joined(separator: "\n\n")
            var current = figure.chart
            var notes: [String] = []
            var result = ReviewResult.unresolved
            var lastProblems: [String] = []
            // Points the picture's own curves pass through, read from its pixels at its tick labels: what the
            // formulas must fit (eyes alone misjudge a parabola's width).
            let measured = await Self.measuredCurves(png: png, hints: current)
            for _ in 0...max(1, rounds) {  // rounds of correction, and a last look at the final one
                let redraw: Data? = current == nil ? nil : await render(current!, png)
                let verdict: FigureReviewer.Verdict
                do {
                    verdict = try await reviewer.review(original: png, redraw: redraw, chart: current, questionText: text,
                                                        caption: figure.caption, notes: notes, measured: measured)
                } catch {
                    lastProblems = ["review failed: \(error.localizedDescription)"]
                    break
                }
                lastProblems = verdict.problems
                if verdict.notRedrawable, verdict.chart == nil { result = .notRedrawable; break }
                if verdict.correct, current != nil { result = .confirmed; break }
                // Only cosmetic differences left: the redraw stands (with the small fixes, when given and drawable).
                if verdict.onlyMinor, current != nil {
                    if let fixed = verdict.chart, await render(fixed, png) != nil { current = fixed }
                    result = .confirmed
                    break
                }
                guard let proposed = verdict.chart else { notes = verdict.problems + ["Give the corrected chart in full in `chart`."]; continue }
                // The reviewer has seen both pictures, so its chart is taken as given (the app's own fits would
                // second-guess it: cut a t-range, add a vector's head as an arrowhead). The picture check only
                // reports, and what it finds goes into the next round with the reviewer's own list.
                var checked = proposed
                if FigureAgent.isShapeChart(checked), let verdict = await ShapeVerifier.verify(checked, png: png, engine: engine) {
                    checked.verification = verdict
                } else {
                    checked.verification = nil
                }
                current = checked
                notes = verdict.problems
                if checked.verification?.passed == false, let summary = checked.verification?.summary { notes.append("The app's picture check: \(summary)") }
            }
            switch result {
            case .confirmed:
                var chart = current!
                chart.notes = [chart.notes, confirmedNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
                chart.confidence = max(chart.confidence, 0.9)
                // Misread text carried in from earlier passes ("35|") goes, as on any chart with axes.
                if !chart.axesHidden, let annotations = chart.annotations {
                    let kept = annotations.filter { PictureText.isPlainLabel($0.text) }
                    chart.annotations = kept.isEmpty ? nil : kept
                }
                figure.kind = .chart
                figure.chart = chart
                figure.status = .accepted
            case .notRedrawable:
                if figure.status == .accepted || figure.status == .reviewing || figure.status == .pending { figure.status = .keptOriginal }
            case .unresolved:
                // Not shown as a redraw until it is right: the original stays in front of the student.
                if figure.status == .accepted || figure.status == .pending { figure.status = .reviewing }
            case .skipped:
                break
            }
            try await store.update(figure)
            // For an unresolved figure, the last chart's formulas too (what the reviewer wrote that does not draw).
            var reported = lastProblems
            if result == .unresolved, let chart = current {
                reported.append("last chart: " + chart.series.map { s in
                    [s.kind ?? "curve", s.latex, s.xt.map { "x=" + $0 }, s.yt.map { "y=" + $0 }, s.tRange.map { "t\($0)" }]
                        .compactMap { $0 }.joined(separator: " ")
                }.joined(separator: "; "))
            }
            report?(figure, result, reported)
            outcomes.append(Outcome(figureId: figure.id, index: figure.pageOrIndex, kind: figure.kind, isFigure: true,
                                    verification: figure.chart?.verification, caption: figure.caption, definition: figure.chart?.definition))
        }
        return outcomes
    }
}
