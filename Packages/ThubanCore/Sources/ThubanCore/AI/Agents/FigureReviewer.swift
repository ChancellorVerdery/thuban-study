import Foundation

/// A second look at a redraw, the way a student would judge it: the original picture and the app's redraw side by
/// side. The reviewer says whether the redraw is right and, when it is not, returns the corrected chart (the same
/// schema the figure agent fills), which the app draws, checks against the picture and shows the reviewer again.
public actor FigureReviewer {
    public static let toolName = "review_redraw"

    public struct Verdict: Sendable {
        /// The redraw matches the original in everything the checklist covers.
        public var correct: Bool
        /// What is wrong, one problem per entry (empty when correct).
        public var problems: [String]
        /// The corrected chart, when the redraw was wrong (or missing) and the picture can be redrawn.
        public var chart: StandardChart?
        /// The picture is not a plot or diagram the app can redraw (a photo, a 3D surface, a table).
        public var notRedrawable: Bool
        /// What is left is cosmetic only (a student would not notice it or it changes nothing): the redraw, with
        /// any small correction given, is right.
        public var onlyMinor: Bool
    }

    static let spec = ToolSpec(
        name: toolName,
        description: "Judge the redraw against the original and, when it is wrong or missing, give the corrected chart.",
        inputSchema: [
            "type": "object",
            "properties": [
                "correct": ["type": "boolean", "description": "true only when the redraw shows the same figure as the original in every point of the checklist."],
                "problems": ["type": "array", "items": ["type": "string"], "description": "Each difference from the original, precisely (what, where, the right value). Empty when correct."],
                "onlyMinor": ["type": "boolean", "description": "true when every remaining difference is cosmetic — something a student comparing the two would not notice or that changes nothing about the figure's meaning (a scaled tangent vector a little longer or shorter, a point 0.1 off, slightly different spacing of tick numbers, colours). You may still give a chart with small fixes."],
                "notRedrawable": ["type": "boolean", "description": "true when the original cannot be redrawn as a chart at all (a photo, a 3D surface or solid, a table, a picture of an apparatus)."],
                "chart": FigureAgent.chartSchema,
            ],
            "required": ["correct", "problems"],
        ]
    )

    static let instructions = """
    You are checking a study app's redraw of a textbook figure. You see the ORIGINAL picture and the app's REDRAW \
    (drawn from the chart you are also given as JSON, in the app's own colours, which are expected to differ from the \
    original's). Judge the redraw strictly against the original:
    - The same curves, lines and regions: right formulas, right shape, right extent (a parametric curve covers the \
      same t-range — no missing branch, no extra loop or stub; a segment stops at its endpoints). Every curve the \
      original shows, and no extra one. Smooth where the original is smooth (a wobbly or kinked trace is wrong).
    - Shading exactly where the original shades; a dashed boundary stays dashed (strict inequality), a solid one solid.
    - Points the original marks with dots are drawn at their exact coordinates, with their printed labels.
    - Vectors: tail, head, length and direction as the original draws them; their printed names.
    - Arrowheads along curves in the same places and directions as the original.
    - Families of curves: the same number of curves, spacing and convergence.
    - The window and axes placed like the original's (axes centred where the original's are, similar range, no \
      clipping of what the original shows); tick numbers only where the original has them.
    - Distinct roles keep distinct colours when the original uses colours (curve vs vectors vs dots).
    - A diagram without axes (vectors on plain paper, a triangle or parallelogram of vectors, an angle) is a chart \
      with `showAxes` false, drawn to the same proportions, with its labels, tick marks and angle marks.

    When the redraw is wrong or missing, give the corrected chart in full (not a patch) with exact formulas read \
    from the picture and the question: lines and curves as `latex`, parametric curves as `xt`/`yt` with `tRange`, \
    regions as inequalities, points as "point" series with `labels`, vectors as "vector" series. Never give a \
    curve as traced `points` when a formula fits — work out the formula (a line through two grid points, a parabola \
    through its vertex and a point, x = t^5, y = t^6, a semicircle). Keep everything that was already right. Set \
    `xRange`/`yRange` to the original's window. A curve's arrowheads: set `directionArrows`. Set `correct` to false \
    whenever you return a chart.

    A parametric curve's `tRange` must reach exactly as far as the original's curve does: solve for t at each \
    visible end (where the curve stops, or where it leaves the window — then take the t slightly beyond the edge so \
    the curve runs off it as in the original). Check your formula against the measured points before answering: \
    substitute two or three of them.

    Arrowheads along a curve (`directionArrows`) are drawn spaced along it, pointing the way t increases. To make \
    them point the other way, reverse the parametrization: replace t by −t in `xt` and `yt` and negate and swap the \
    `tRange`. A curve written as `latex` y = f(x) has its arrows pointing toward increasing x; give it as a \
    parametric curve (x = t, y = f(t), or x = −t, y = f(−t)) when the original's arrows point the other way.

    Coordinates you report must be read from the original's grid and tick labels, not guessed from the redraw.

    The app draws every figure in its own house style — its colours, light gridlines, line widths, fonts, a '0' at \
    the origin — so never report those. When the original prints no tick numbers on an axis, give `xTicks: []` / \
    `yTicks: []` and the redraw prints none.

    Judge as a student would: what matters is the right curves, regions, points, vectors and labels in the right     places, the same look of the figure. Differences only a ruler would find (a tangent vector drawn to a slightly     different scale — textbooks often scale them —, a point a tenth of a unit off, a label's exact position, colours)     are not problems: set `onlyMinor` true for them. Do not chase them round after round. Something missing or \
    extra is never minor: a printed label, an angle or right-angle mark, a tick mark, a dot, an arrowhead, a curve.
    """

    private let client: ClaudeClient
    private let model: ClaudeModel

    public init(client: ClaudeClient, model: ClaudeModel = .opus) {
        self.client = client
        self.model = model
    }

    /// One review: the original, the redraw (nil when there is none yet), the chart behind it, the question it
    /// belongs to and what earlier rounds and the picture check found.
    public func review(original: Data, redraw: Data?, chart: StandardChart?, questionText: String,
                       caption: String?, notes: [String], measured: String? = nil) async throws -> Verdict {
        var content: [ContentPart] = [.text("ORIGINAL:"), .image(mediaType: "image/png", base64: original.base64EncodedString())]
        if let redraw {
            content.append(.text("REDRAW (the app's drawing of the chart below):"))
            content.append(.image(mediaType: "image/png", base64: redraw.base64EncodedString()))
        } else {
            content.append(.text("There is no redraw yet: the app shows the original. Give the chart that redraws it, unless it cannot be redrawn."))
        }
        var text: [String] = []
        if let chart, let data = try? JSONEncoder().encode(Self.trimmed(chart)), let json = String(data: data, encoding: .utf8) {
            text.append("The chart behind the redraw:\n\(json.prefix(12000))")
        }
        if let caption, !caption.isEmpty { text.append("The figure's caption: \(caption.prefix(400))") }
        let question = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !question.isEmpty { text.append("The question this figure belongs to:\n\(question.prefix(5000))") }
        if let measured, !measured.isEmpty {
            text.append("Points the original's curves pass through, measured from its pixels at its tick labels (each curve's points in order along it; a curve may be split where it crosses an axis or a label; axes and grid excluded). Fit your formulas to these:\n\(measured.prefix(6000))")
        }
        if !notes.isEmpty { text.append("From the previous round (fix these):\n" + notes.map { "- " + $0 }.joined(separator: "\n")) }
        content.append(.text(text.joined(separator: "\n\n")))
        let response = try await client.complete(
            model: model,
            system: Prompts.figureSystem() + "\n\n" + Self.instructions,
            messages: [ChatMessage.user(content)],
            tools: [Self.spec],
            maxTokens: 12000,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("The figure reviewer gave no verdict.")
        }
        let input = call.input
        var proposed: StandardChart?
        var unreadable: String?
        if let raw = input["chart"], let data = try? raw.data() {
            do { _ = try JSONDecoder().decode(StandardChart.self, from: data) } catch { unreadable = "Your chart could not be read: \(error)" }
        }
        if let raw = input["chart"], let data = try? raw.data(), let chart = try? JSONDecoder().decode(StandardChart.self, from: data),
           !chart.series.isEmpty || chart.hasPanels {
            proposed = chart
            // Axes the original leaves unnumbered (an explicit empty list of ticks) carry no numbers in the redraw.
            if chart.xTicks?.isEmpty == true { proposed?.xAxisLabels = [] }
            if chart.yTicks?.isEmpty == true { proposed?.yAxisLabels = [] }
            if proposed?.provenance == nil {
                proposed?.provenance = chart.series.contains(where: { ($0.latex ?? "").isEmpty == false || $0.xt != nil }) ? StandardChart.stated : StandardChart.traced
            }
        }
        var problems = input["problems"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let unreadable { problems.append(String(unreadable.prefix(600))) }
        let correct = input["correct"]?.boolValue == true && proposed == nil
        return Verdict(correct: correct, problems: problems, chart: proposed, notRedrawable: input["notRedrawable"]?.boolValue == true,
                       onlyMinor: input["onlyMinor"]?.boolValue == true)
    }

    /// The chart as the reviewer needs it: without the app's own bookkeeping (verification text, shape candidates).
    static func trimmed(_ chart: StandardChart) -> StandardChart {
        var chart = chart
        chart.verification = nil
        chart.shapeCandidates = nil
        return chart
    }
}
