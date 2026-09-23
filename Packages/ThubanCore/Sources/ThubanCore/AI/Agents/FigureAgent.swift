import Foundation

/// What the figure agent concluded about one extracted image.
public struct FigureAnalysis: Codable, Sendable, Equatable {
    public var kind: FigureKind
    /// Present when `kind == .chart` and the model could read the data.
    public var chart: StandardChart?
    public var caption: String?
    /// False when the image is not a figure at all (an equation fragment, a lone symbol, an icon or logo, page
    /// chrome, a blank); the import drops such images instead of listing them under Figures.
    public var isFigure: Bool

    public init(kind: FigureKind, chart: StandardChart? = nil, caption: String? = nil, isFigure: Bool = true) {
        self.kind = kind
        self.chart = chart
        self.caption = caption
        self.isFigure = isFigure
    }
}

/// Classifies extracted figures and, for charts, produces a `StandardChart` the app can redraw in its own style.
///
/// The workflow is per question: the agent sees the question's figures one at a time, in document order, and is
/// told what the earlier ones turned out to be (`describeInSequence`) — several near-identical sketches in one
/// message get mixed up, one at a time they do not; it must find the function or slope field in the question
/// text, read check points off the picture so the app can verify the match (`FigureVerifier`), and only trace an
/// arbitrary curve as points when nothing in the question defines it.
public actor FigureAgent {
    public static let toolName = "describe_figures"
    /// Images per call; a question with more figures is split.
    public static let maxImagesPerCall = 8

    static let chartSchema: JSONValue = [
        "type": "object",
        "properties": [
            "chartType": ["type": "string", "enum": ["line", "scatter", "bar", "function", "histogram", "slopeField"]],
            "provenance": [
                "type": "string", "enum": ["stated", "traced"],
                "description": "\"stated\" when the function or slope field is defined somewhere in the question (then give it as `latex`/`slope` and read `checks`); \"traced\" when nothing in the question defines the curve and you read it off the picture as `points`.",
            ],
            "definition": ["type": "string", "description": "The definition as the question states it, quoted with where it was found, e.g. \"part (b): dy/dx = x - y, y(0) = 1\". Empty when traced."],
            "checks": [
                "type": "array",
                "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 3],
                "description": "Stated charts only: 3–6 points you read off the picture to test the definition, spread across the window and including any marked points and axis crossings. For a curve [x, y]. For a slope field [x, y, m] with m the slope of the arrow at (x, y) (pick arrows whose direction is clear), plus [x, y] points along any solution curve drawn over it. The app evaluates the equation at these and rejects a mismatch.",
            ],
            "slope": ["type": "string", "description": "slopeField only: the right-hand side of dy/dx = f(x, y) in LaTeX, e.g. \"x-y\" or \"\\\\sin(x)+y^{2}\"."],
            "candidates": [
                "type": "array",
                "items": ["type": "object", "properties": ["label": ["type": "string"], "x": ["type": "number"], "y": ["type": "number"]], "required": ["label", "x", "y"]],
                "description": "slopeField only: every initial condition the question offers for a solution curve — each part's and each answer choice's — as {label: \"part (a) y(-2) = 1\", x: -2, y: 1}, whether or not you think this picture shows it. The app draws each one and keeps the one that fits the drawn curve.",
            ],
            "arrows": ["type": "boolean", "description": "slopeField only: true when the field is drawn with arrowheads (a direction field), false for plain ticks."],
            "fieldColumns": ["type": "integer", "description": "slopeField only: how many arrows across one row of the original."],
            "fieldRows": ["type": "integer", "description": "slopeField only: how many arrows down one column of the original."],
            "xTicks": ["type": "array", "items": ["type": "number"], "description": "Every numeric label printed along the x-axis, left to right, exactly as printed (e.g. [-3, -2, -1, 1, 2, 3]); omit symbolic labels like c."],
            "yTicks": ["type": "array", "items": ["type": "number"], "description": "Every numeric label printed along the y-axis, top to bottom, exactly as printed (e.g. [1.7, 0.5, -2.2])."],
            "xStep": ["type": "number", "description": "Spacing of the x-axis ticks/gridlines in the original (e.g. 1, 0.5, 5)."],
            "yStep": ["type": "number", "description": "Spacing of the y-axis ticks/gridlines in the original."],
            "notes": ["type": "string", "description": "Everything else needed to reproduce the picture: marked points and labels, where each curve enters and leaves the window, dashed or dotted parts, asymptotes, shading, which quadrants are shown."],
            "xLabel": ["type": "string"],
            "yLabel": ["type": "string"],
            "series": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "points": [
                            "type": "array",
                            "items": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                            "description": "Traced curves: [[x, y], …] read off the axes along the curve, 12–40 of them, in order; the app draws a smooth curve through them (dots only for scatter charts). Never one point per arrow of a field.",
                        ],
                        "latex": ["type": "string", "description": "Stated curves: the function of x (or relation) exactly as the question gives it. Preferred over points whenever the question defines the curve."],
                        "through": [
                            "type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2,
                            "description": "slopeField only: [x0, y0] the solution curve passes through (its initial condition). The app integrates the curve from it; never trace a solution curve as points.",
                        ],
                        "color": ["type": "string", "description": "Optional hex color."],
                        "style": ["type": "string", "enum": ["solid", "dashed", "dotted"], "description": "How the original draws this curve."],
                    ],
                    "required": ["name"],
                ],
            ],
            "xRange": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
            "yRange": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
        ],
        "required": ["chartType", "provenance", "series", "confidence"],
    ]

    public static let spec = ToolSpec(
        name: toolName,
        description: "Describe the attached images, one entry per image number. Fill `chart` only when kind is \"chart\".",
        inputSchema: [
            "type": "object",
            "properties": [
                "figures": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "image": ["type": "integer", "description": "The image number (1 = the first attached image)."],
                            "isFigure": [
                                "type": "boolean",
                                "description": "true only for a real figure a student would refer to (chart, diagram, table, photo). false for a rendered equation or a fragment of one, a lone symbol or bracket, an icon, logo, button, rule, spacer, or a blank/illegible image.",
                            ],
                            "kind": ["type": "string", "enum": ["chart", "diagram", "photo", "table", "unknown"]],
                            "caption": ["type": "string", "description": "One useful sentence for a student; for a chart, say which definition it shows and which part or choice it belongs to."],
                            "chart": chartSchema,
                        ],
                        "required": ["image", "isFigure", "kind", "caption"],
                    ],
                ],
            ],
            "required": ["figures"],
        ]
    )

    private let client: ClaudeClient
    private let model: ClaudeModel
    private let maxTokens: Int

    /// What the figure agent is told besides the images.
    public struct FigureContext: Sendable, Equatable {
        /// Document text around the figure(s) (before and after).
        public var nearbyText: String
        /// The questions that cite the figure(s), in full (stem and parts), as Markdown + LaTeX.
        public var questionTexts: [String]
        /// An earlier caption or analysis note, if any.
        public var previousCaption: String?
        /// Stems of the document's other questions (for a figure no question cites, the equation is usually in one).
        public var otherQuestionTexts: [String]
        /// "Image 3 of 8 the question refers to, in document order" — helps pair sketches with parts/choices.
        public var positionNote: String?
        /// How many images are attached: every figure under the question, in document order, numbered from 1.
        public var imageCount: Int
        /// Describe only these image numbers; the rest are attached for context. nil = describe all.
        public var focus: [Int]?
        /// What the app found when it checked the previous pass against the picture (`FigureVerifier`), so the
        /// agent can pick another candidate or fall back to tracing.
        public var verificationFeedback: String?
        /// The question's other figures, one line each ("Image 2 of 4: … — part (a) y(−2) = 1"), so this one is
        /// paired with a part or choice none of them already took.
        public var siblingNotes: [String]
        /// A slope field already read from another figure of the same question (its equation, window and
        /// candidates), so a sketch the agent cannot describe still gets the field and its curve from the pixels.
        public var siblingField: StandardChart?

        public init(nearbyText: String = "", questionTexts: [String] = [], previousCaption: String? = nil,
                    otherQuestionTexts: [String] = [], positionNote: String? = nil, imageCount: Int = 1,
                    focus: [Int]? = nil, verificationFeedback: String? = nil, siblingNotes: [String] = []) {
            self.nearbyText = nearbyText
            self.questionTexts = questionTexts
            self.previousCaption = previousCaption
            self.otherQuestionTexts = otherQuestionTexts
            self.positionNote = positionNote
            self.imageCount = imageCount
            self.focus = focus
            self.verificationFeedback = verificationFeedback
            self.siblingNotes = siblingNotes
        }

        /// The text block sent with the images.
        public var rendered: String {
            var parts: [String] = []
            if imageCount > 1 {
                var line = "Attached are \(imageCount) images: every figure under this question, in document order, numbered 1 to \(imageCount). "
                if let focus, !focus.isEmpty {
                    let list = focus.map(String.init).joined(separator: ", ")
                    line += "Describe only image\(focus.count == 1 ? "" : "s") \(list); the others are attached so you can tell which image is the field, which are the candidate sketches, and which part or choice each one answers."
                } else {
                    line += "Describe every image, one entry each, in the single `describe_figures` call; use the set to tell the field from the sketches and to give each sketch a different part or choice."
                }
                parts.append(line)
            }
            let questions = questionTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !questions.isEmpty {
                parts.append("The question(s) the figure\(imageCount > 1 ? "s" : "") belong\(imageCount > 1 ? "" : "s") to — look here first for the function or slope field each picture shows:\n\n"
                    + questions.enumerated().map { "Question \($0.offset + 1):\n\($0.element.prefix(3000))" }.joined(separator: "\n\n"))
            }
            if let positionNote = positionNote?.trimmingCharacters(in: .whitespacesAndNewlines), !positionNote.isEmpty {
                parts.append(positionNote)
            }
            let siblings = siblingNotes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !siblings.isEmpty {
                parts.append("The other figures under this question, and what they turned out to be:\n"
                    + siblings.prefix(12).map { "• " + $0.prefix(400) }.joined(separator: "\n")
                    + "\nEach sketch answers a different part or choice, so do not give this image a part, choice or initial "
                    + "condition already taken above unless its curve plainly is the same one; read this picture's own curve and test the remaining candidates against it.")
            }
            let nearby = nearbyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nearby.isEmpty {
                parts.append("Text around the figure\(imageCount > 1 ? "s" : "") in the document ([figure here] marks a figure's place):\n\n\(nearby.prefix(6000))")
            }
            let others = otherQuestionTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !others.isEmpty {
                parts.append("Other problems in the same document (the figure may belong to one of these):\n\n"
                    + others.prefix(12).map { "• " + $0.prefix(500) }.joined(separator: "\n"))
            }
            if let previousCaption = previousCaption?.trimmingCharacters(in: .whitespacesAndNewlines), !previousCaption.isEmpty {
                parts.append("An earlier description of this image: \(previousCaption.prefix(400))")
            }
            if let feedback = verificationFeedback?.trimmingCharacters(in: .whitespacesAndNewlines), !feedback.isEmpty {
                parts.append("The app evaluated your previous description's equation at the points you read off the picture and it did not match:\n\(feedback.prefix(2000))\n\n"
                    + "Fix it: re-read the question for another candidate (a different part, choice or initial condition) and test it against the picture; "
                    + "if no definition in the question fits, set `provenance` to \"traced\" and give the curve as 12–40 `points` instead of an equation.")
            }
            return parts.isEmpty ? "There is no surrounding text." : parts.joined(separator: "\n\n")
        }
    }

    public init(client: ClaudeClient, model: ClaudeModel = .sonnet, maxTokens: Int = 8192) {
        self.client = client
        self.model = model
        self.maxTokens = maxTokens
    }

    /// Sends the PNG plus the surrounding text and decodes its description.
    public func analyze(png: Data, nearbyText: String) async throws -> FigureAnalysis {
        try await analyze(png: png, context: FigureContext(nearbyText: nearbyText))
    }

    /// One image with everything known about where it came from.
    public func analyze(png: Data, context: FigureContext) async throws -> FigureAnalysis {
        var context = context
        context.imageCount = 1
        context.focus = nil
        let results = try await analyze(pngs: [png], context: context)
        guard let analysis = results[1] ?? results.values.first else {
            throw ThubanError.parse("The figure agent did not describe the figure.")
        }
        return analysis
    }

    /// All the figures under one question in a single call, keyed by image number (1-based, in the order given).
    /// Images the agent left out are simply absent from the result.
    public func analyze(pngs: [Data], context: FigureContext) async throws -> [Int: FigureAnalysis] {
        guard !pngs.isEmpty else { return [:] }
        guard pngs.allSatisfy({ !$0.isEmpty }) else { throw ThubanError.parse("The figure image is empty.") }
        guard pngs.count <= Self.maxImagesPerCall else { throw ThubanError.parse("At most \(Self.maxImagesPerCall) figures go in one call.") }
        var context = context
        context.imageCount = pngs.count
        var content: [ContentPart] = []
        for (offset, png) in pngs.enumerated() {
            if pngs.count > 1 { content.append(.text("Image \(offset + 1):")) }
            content.append(.image(mediaType: "image/png", base64: png.base64EncodedString()))
        }
        content.append(.text(context.rendered))
        let response = try await client.complete(
            model: model,
            system: Prompts.figureSystem(),
            messages: [ChatMessage.user(content)],
            tools: [Self.spec],
            maxTokens: maxTokens,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("The figure agent did not describe the figures.")
        }
        return Self.analyses(from: call.input, imageCount: pngs.count)
    }

    /// The full workflow for one question's figures: describe, verify each stated chart against the points the
    /// agent read (`FigureVerifier`), and give the agent one more pass on the ones that did not match, with the
    /// mismatch spelled out. Charts that still fail keep their equation and a failed `verification` so the review
    /// page can flag them.
    public func analyzeVerified(pngs: [Data], context: FigureContext, engine: MathEngine) async throws -> [Int: FigureAnalysis] {
        var results = try await analyze(pngs: pngs, context: context)
        var feedback: [String] = []
        var retry: [Int] = []
        for image in results.keys.sorted() {
            guard let analysis = results[image], analysis.isFigure, analysis.kind == .chart else { continue }
            guard let chart = analysis.chart else {
                // Called a chart but not described: ask once more, then let the picture alone give its curves.
                feedback.append((pngs.count > 1 ? "Image \(image): " : "") + "you set kind to \"chart\" but gave no `chart`; fill it in (or set kind to \"diagram\" if it is not a plot).")
                retry.append(image)
                continue
            }
            let checked = await Self.check(chart, png: pngs[image - 1], engine: engine)
            results[image]?.chart = checked
            if let verdict = checked.verification, !verdict.passed {
                feedback.append((pngs.count > 1 ? "Image \(image): " : "") + verdict.summary)
                retry.append(image)
            }
        }
        if !retry.isEmpty {
            try Task.checkCancellation()
            var second = context
            second.focus = pngs.count > 1 ? retry : nil
            second.verificationFeedback = feedback.joined(separator: "\n")
            let again = try await analyze(pngs: pngs, context: second)
            for image in retry {
                guard var analysis = again[image] else { continue }
                if let chart = analysis.chart {
                    analysis.chart = await Self.check(chart, png: pngs[image - 1], engine: engine)
                }
                results[image] = analysis
            }
        }
        for image in results.keys.sorted() {
            guard var analysis = results[image], analysis.isFigure, analysis.kind == .chart else { continue }
            if analysis.chart == nil {
                analysis.chart = await FigureReconciler.chartFromPixels(png: pngs[image - 1], hints: context.siblingField, engine: engine)
            }
            // A "chart" that is not a plot — a phase line, a sketch with a couple of points and no equation — in a
            // picture the reader cannot read either is a diagram: the original image serves the student better.
            if let chart = analysis.chart, Self.isThin(chart) {
                analysis.kind = .diagram
                analysis.chart = nil
            }
            results[image] = analysis
        }
        return results
    }

    /// No equation, no field, no initial condition, and only a handful of points per series.
    public static func isThin(_ chart: StandardChart) -> Bool {
        guard (chart.slope ?? "").isEmpty, !chart.isSlopeField else { return false }
        // A vertical line ("x = 0": a phase line's axis) or a handful of points is not a plot.
        let verticalLine = try! NSRegularExpression(pattern: #"^\s*x\s*=\s*-?[0-9.]*\s*$"#)
        return chart.series.allSatisfy { series in
            if let latex = series.latex?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty {
                return verticalLine.firstMatch(in: latex, range: NSRange(latex.startIndex..., in: latex)) != nil
            }
            return series.throughPoint == nil && (series.points?.count ?? 0) < 8
        }
    }

    /// The picture decides: the chart reconciled against its pixels (`FigureReconciler`) when the picture can be
    /// read, else checked against the agent's own read points (`FigureVerifier`).
    public static func check(_ chart: StandardChart, png: Data, engine: MathEngine) async -> StandardChart {
        if let reconciled = await FigureReconciler.reconcile(chart, png: png, engine: engine) { return reconciled }
        var checked = chart
        checked.verification = await FigureVerifier.verify(chart, engine: engine)
        return checked
    }

    /// The per-question workflow: the figures under one question, one call each in document order, each verified
    /// (`analyzeVerified`) and each told what the earlier figures turned out to be, so a sketch is never given a
    /// part another sketch already has and no image is ever confused with its neighbour. `siblingNotes` in
    /// `context` seeds the list (figures described earlier, e.g. on a re-analyse). Keyed by image number, 1-based.
    public func describeInSequence(pngs: [Data], context: FigureContext, engine: MathEngine,
                                   progress: ((Int) -> Void)? = nil) async throws -> [Int: FigureAnalysis] {
        var results: [Int: FigureAnalysis] = [:]
        var notes = context.siblingNotes
        for (offset, png) in pngs.enumerated() {
            try Task.checkCancellation()
            progress?(offset + 1)
            var one = context
            one.imageCount = 1
            one.focus = nil
            one.siblingNotes = notes
            if let field = results.values.compactMap(\.chart).last(where: { $0.isSlopeField && !($0.slope ?? "").isEmpty }) { one.siblingField = field }
            if pngs.count > 1 {
                one.positionNote = "This is image \(offset + 1) of \(pngs.count) under this question, in document order."
            }
            var analysis: FigureAnalysis?
            do {
                analysis = try await analyzeVerified(pngs: [png], context: one, engine: engine)[1]
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ThubanError where error == .cancelled || error.isCredentialProblem {
                throw error
            } catch {
                // One bad call (a timeout, an overloaded reply) must not leave this figure pending: wait, then
                // try twice more before giving up on it and going on with the rest.
                for pause in [3.0, 8.0] {
                    try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                    if let again = try? await analyzeVerified(pngs: [png], context: one, engine: engine)[1] { analysis = again; break }
                }
            }
            if analysis == nil {
                // An empty answer (no entry for the image) gets the same second chance.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                analysis = try? await analyzeVerified(pngs: [png], context: one, engine: engine)[1]
            }
            guard let analysis else { continue }
            results[offset + 1] = analysis
            if pngs.count > 1, let note = Self.siblingNote(analysis, image: offset + 1, of: pngs.count) { notes.append(note) }
        }
        return results
    }

    /// One line about an already-described figure for the next one's context.
    public static func siblingNote(_ analysis: FigureAnalysis, image: Int, of count: Int) -> String? {
        guard analysis.isFigure else { return nil }
        var line = "Image \(image) of \(count): \(analysis.caption ?? analysis.kind.rawValue)"
        if let chart = analysis.chart {
            if let definition = chart.definition?.trimmingCharacters(in: .whitespacesAndNewlines), !definition.isEmpty {
                line += " — \(definition)"
            } else if chart.isTraced {
                line += " — traced from points (no definition in the question)"
            }
            let conditions = chart.series.compactMap(\.throughPoint).map { "(\(ChartGeometry.number($0.x)), \(ChartGeometry.number($0.y)))" }
            if !conditions.isEmpty { line += " — solution through \(conditions.joined(separator: ", "))" }
        }
        return line
    }

    /// Lenient decoding of the tool input: every entry with a usable image number.
    static func analyses(from input: JSONValue, imageCount: Int) -> [Int: FigureAnalysis] {
        var results: [Int: FigureAnalysis] = [:]
        let entries = input["figures"]?.arrayValue ?? []
        for (offset, entry) in entries.enumerated() {
            // A missing image number means "in order" (a single image is always image 1).
            let image = entry["image"]?.intValue ?? (imageCount == 1 ? 1 : offset + 1)
            guard image >= 1, image <= imageCount, results[image] == nil else { continue }
            results[image] = analysis(from: entry)
        }
        return results
    }

    /// Lenient decoding of one entry.
    static func analysis(from input: JSONValue) -> FigureAnalysis {
        let kind = input["kind"]?.stringValue.flatMap(FigureKind.init(rawValue:)) ?? .unknown
        let isFigure = input["isFigure"]?.boolValue ?? true
        let caption = input["caption"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var chart: StandardChart?
        if kind == .chart, let raw = input["chart"], let data = try? raw.data() {
            chart = try? JSONDecoder().decode(StandardChart.self, from: data)
            // A chart needs something to draw: series, or a slope field's equation (a field alone is a chart).
            if let c = chart, c.series.isEmpty, !(c.isSlopeField && !(c.slope ?? "").isEmpty) { chart = nil }
            // Provenance follows from what was given when the agent forgot to say.
            if var c = chart, c.provenance == nil {
                let hasEquation = !(c.slope ?? "").isEmpty || c.series.contains { !($0.latex ?? "").isEmpty }
                c.provenance = hasEquation ? StandardChart.stated : StandardChart.traced
                chart = c
            }
        }
        return FigureAnalysis(kind: kind, chart: chart, caption: caption.flatMap { $0.isEmpty ? nil : $0 }, isFigure: isFigure)
    }
}
