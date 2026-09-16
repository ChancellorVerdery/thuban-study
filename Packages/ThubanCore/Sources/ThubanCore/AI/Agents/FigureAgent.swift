import Foundation

/// What the figure agent concluded about one extracted image.
public struct FigureAnalysis: Codable, Sendable, Equatable {
    public var kind: FigureKind
    /// Present when `kind == .chart` and the model could read the data.
    public var chart: StandardChart?
    public var caption: String?

    public init(kind: FigureKind, chart: StandardChart? = nil, caption: String? = nil) {
        self.kind = kind
        self.chart = chart
        self.caption = caption
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
                "kind": ["type": "string", "enum": ["chart", "diagram", "photo", "table", "unknown"]],
                "caption": ["type": "string", "description": "One useful sentence for a student."],
                "chart": [
                    "type": "object",
                    "properties": [
                        "chartType": ["type": "string", "enum": ["line", "scatter", "bar", "function", "histogram"]],
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
                                        "description": "[[x, y], …] read off the axes.",
                                    ],
                                    "latex": ["type": "string", "description": "A function of x when the curve is a known function."],
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
            "required": ["kind", "caption"],
        ]
    )

    private let client: ClaudeClient
    private let model: ClaudeModel
    private let maxTokens: Int

    public init(client: ClaudeClient, model: ClaudeModel = .sonnet, maxTokens: Int = 4096) {
        self.client = client
        self.model = model
        self.maxTokens = maxTokens
    }

    /// Sends the PNG plus the surrounding text and decodes the `describe_figure` call.
    public func analyze(png: Data, nearbyText: String) async throws -> FigureAnalysis {
        guard !png.isEmpty else { throw ThubanError.parse("The figure image is empty.") }
        let context = nearbyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = context.isEmpty ? "There is no surrounding text." : "Text near the figure in the document:\n\n\(context.prefix(2000))"
        let message = ChatMessage.user([
            .image(mediaType: "image/png", base64: png.base64EncodedString()),
            .text(note),
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
        let caption = input["caption"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var chart: StandardChart?
        if kind == .chart, let raw = input["chart"], let data = try? raw.data() {
            chart = try? JSONDecoder().decode(StandardChart.self, from: data)
            if let c = chart, c.series.isEmpty { chart = nil }
        }
        return FigureAnalysis(kind: kind, chart: chart, caption: caption.flatMap { $0.isEmpty ? nil : $0 })
    }
}
