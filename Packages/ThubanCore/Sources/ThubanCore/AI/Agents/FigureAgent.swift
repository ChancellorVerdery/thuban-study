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

/// Classifies an extracted figure and, for charts, produces a `StandardChart` the app can redraw in its own style.
public actor FigureAgent {
    public static let toolName = "describe_figure"

    public static let spec = ToolSpec(
        name: toolName,
        description: "Describe the figure. Fill `chart` only when kind is \"chart\".",
        inputSchema: [
            "type": "object",
            "properties": [
                "isFigure": [
                    "type": "boolean",
                    "description": "true only for a real figure a student would refer to (chart, diagram, table, photo). false for a rendered equation or a fragment of one, a lone symbol or bracket, an icon, logo, button, rule, spacer, or a blank/illegible image.",
                ],
                "kind": ["type": "string", "enum": ["chart", "diagram", "photo", "table", "unknown"]],
                "caption": ["type": "string", "description": "One useful sentence for a student."],
                "chart": [
                    "type": "object",
                    "properties": [
                        "chartType": ["type": "string", "enum": ["line", "scatter", "bar", "function", "histogram", "slopeField"]],
                        "slope": ["type": "string", "description": "slopeField only: the right-hand side of dy/dx = f(x, y) in LaTeX, e.g. \"x-y\" or \"\\\\sin(x)+y^{2}\"."],
                        "arrows": ["type": "boolean", "description": "slopeField only: true when the field is drawn with arrowheads (a direction field), false for plain ticks."],
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
                                        "description": "[[x, y], …] read off the axes along the curve, 12–40 of them, in order; the app draws a smooth curve through them (dots only for scatter charts). Never one point per arrow of a field.",
                                    ],
                                    "latex": ["type": "string", "description": "A function of x when the curve is a known function (preferred over points)."],
                                    "through": [
                                        "type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2,
                                        "description": "slopeField only: [x0, y0] the solution curve passes through (its initial condition). Preferred over points for solution curves; the app integrates the curve from it.",
                                    ],
                                    "color": ["type": "string", "description": "Optional hex color."],
                                ],
                                "required": ["name"],
                            ],
                        ],
                        "xRange": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                        "yRange": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                    ],
                    "required": ["chartType", "series", "confidence"],
                ],
            ],
            "required": ["isFigure", "kind", "caption"],
        ]
    )

    private let client: ClaudeClient
    private let model: ClaudeModel
    private let maxTokens: Int

    /// What the figure agent is told besides the image.
    public struct FigureContext: Sendable, Equatable {
        /// Document text around the figure (before and after).
        public var nearbyText: String
        /// The questions that cite the figure, in full (stem and parts), as Markdown + LaTeX.
        public var questionTexts: [String]
        /// An earlier caption or analysis note, if any.
        public var previousCaption: String?

        public init(nearbyText: String = "", questionTexts: [String] = [], previousCaption: String? = nil) {
            self.nearbyText = nearbyText
            self.questionTexts = questionTexts
            self.previousCaption = previousCaption
        }

        /// The text block sent with the image.
        public var rendered: String {
            var parts: [String] = []
            let questions = questionTexts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !questions.isEmpty {
                parts.append("The question(s) this figure belongs to — look here first for the equation the figure is a graph of:\n\n"
                    + questions.enumerated().map { "Question \($0.offset + 1):\n\($0.element.prefix(3000))" }.joined(separator: "\n\n"))
            }
            let nearby = nearbyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !nearby.isEmpty {
                parts.append("Text around the figure in the document ([figure here] marks its place):\n\n\(nearby.prefix(4000))")
            }
            if let previousCaption = previousCaption?.trimmingCharacters(in: .whitespacesAndNewlines), !previousCaption.isEmpty {
                parts.append("An earlier description of this image: \(previousCaption.prefix(400))")
            }
            return parts.isEmpty ? "There is no surrounding text." : parts.joined(separator: "\n\n")
        }
    }

    public init(client: ClaudeClient, model: ClaudeModel = .sonnet, maxTokens: Int = 4096) {
        self.client = client
        self.model = model
        self.maxTokens = maxTokens
    }

    /// Sends the PNG plus the surrounding text and decodes the `describe_figure` call.
    public func analyze(png: Data, nearbyText: String) async throws -> FigureAnalysis {
        try await analyze(png: png, context: FigureContext(nearbyText: nearbyText))
    }

    /// Sends the PNG with everything known about where it came from — the problem text around it and the
    /// questions that refer to it — so the agent can find the equation the picture is a graph of.
    public func analyze(png: Data, context: FigureContext) async throws -> FigureAnalysis {
        guard !png.isEmpty else { throw ThubanError.parse("The figure image is empty.") }
        let message = ChatMessage.user([
            .image(mediaType: "image/png", base64: png.base64EncodedString()),
            .text(context.rendered),
        ])
        let response = try await client.complete(
            model: model,
            system: Prompts.figureSystem(),
            messages: [message],
            tools: [Self.spec],
            maxTokens: maxTokens,
            toolChoice: .tool(name: Self.toolName)
        )
        guard let call = response.parts.compactMap(\.toolUseValue).first(where: { $0.name == Self.toolName }) else {
            throw ThubanError.parse("The figure agent did not describe the figure.")
        }
        return Self.analysis(from: call.input)
    }

    /// Lenient decoding of the tool input.
    static func analysis(from input: JSONValue) -> FigureAnalysis {
        let kind = input["kind"]?.stringValue.flatMap(FigureKind.init(rawValue:)) ?? .unknown
        let isFigure = input["isFigure"]?.boolValue ?? true
        let caption = input["caption"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var chart: StandardChart?
        if kind == .chart, let raw = input["chart"], let data = try? raw.data() {
            chart = try? JSONDecoder().decode(StandardChart.self, from: data)
            // A chart needs something to draw: series, or a slope field's equation (a field alone is a chart).
            if let c = chart, c.series.isEmpty, !(c.isSlopeField && !(c.slope ?? "").isEmpty) { chart = nil }
        }
        return FigureAnalysis(kind: kind, chart: chart, caption: caption.flatMap { $0.isEmpty ? nil : $0 }, isFigure: isFigure)
    }
}
