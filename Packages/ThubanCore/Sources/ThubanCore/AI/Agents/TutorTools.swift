import Foundation

/// The app-side implementation of the tutor's tools (graph edits, calculator, reading the student's work).
/// Return a JSON object describing the outcome; an object with an `"error"` key is sent back as an error result.
public protocol TutorToolHandler: Sendable {
    func handle(name: String, input: JSONValue) async -> JSONValue
}

/// The eight tools the tutor can call, with their JSON schemas.
public enum TutorTools {
    public static let showGraph = "show_graph"
    public static let hideGraph = "hide_graph"
    public static let graphAddExpression = "graph_add_expression"
    public static let graphRemoveExpression = "graph_remove_expression"
    public static let graphClear = "graph_clear"
    public static let graphSetViewport = "graph_set_viewport"
    public static let showCalculator = "show_calculator"
    public static let getStudentWork = "get_student_work"

    /// Tools that change the graph's contents; withheld when the student disables graph editing.
    public static let graphEditingTools: Set<String> = [graphAddExpression, graphRemoveExpression, graphClear, graphSetViewport]

    /// All eight tool specs.
    public static let specs: [ToolSpec] = [
        ToolSpec(
            name: showGraph,
            description: "Open the graph pane beside the question in 2D or 3D mode. Use before adding expressions.",
            inputSchema: [
                "type": "object",
                "properties": ["mode": ["type": "string", "enum": ["2d", "3d"], "description": "Graph mode."]],
                "required": ["mode"],
            ]
        ),
        ToolSpec(
            name: hideGraph,
            description: "Close the graph pane.",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        ToolSpec(
            name: graphAddExpression,
            description: "Add (or replace, by id) an expression on the graph. Tell the student what you added.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Short stable id, e.g. \"f\", \"tangent1\"."],
                    "latex": ["type": "string", "description": "Desmos-compatible LaTeX, e.g. \"y=x^2\", \"(2,3)\", \"x^2+y^2=4\"."],
                    "color": ["type": "string", "description": "Optional hex color; omit for the theme default."],
                    "dashed": ["type": "boolean", "description": "Draw dashed (for helper lines)."],
                    "label": ["type": "string", "description": "Optional label shown on the graph."],
                    "hidden": ["type": "boolean", "description": "Add but keep hidden."],
                ],
                "required": ["id", "latex"],
            ]
        ),
        ToolSpec(
            name: graphRemoveExpression,
            description: "Remove one expression by id.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
            ]
        ),
        ToolSpec(
            name: graphClear,
            description: "Remove every expression from the graph.",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        ToolSpec(
            name: graphSetViewport,
            description: "Set the visible region of the 2D graph.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "xmin": ["type": "number"], "xmax": ["type": "number"],
                    "ymin": ["type": "number"], "ymax": ["type": "number"],
                ],
                "required": ["xmin", "xmax", "ymin", "ymax"],
            ]
        ),
        ToolSpec(
            name: showCalculator,
            description: "Open the floating scientific calculator for the student.",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        ToolSpec(
            name: getStudentWork,
            description: "Read the student's current inputs and the latest verdicts for every part of the question.",
            inputSchema: ["type": "object", "properties": [:]]
        ),
    ]

    /// The specs offered for a session: everything, or without the graph-editing tools.
    public static func specs(mayEditGraph: Bool) -> [ToolSpec] {
        mayEditGraph ? specs : specs.filter { !graphEditingTools.contains($0.name) }
    }

    /// Student-facing one-liner for the transcript's system line.
    public static func summary(name: String, input: JSONValue) -> String {
        switch name {
        case showGraph:
            return "Opened the \(input["mode"]?.stringValue?.uppercased() ?? "2D") graph"
        case hideGraph:
            return "Closed the graph"
        case graphAddExpression:
            let latex = input["latex"]?.stringValue ?? ""
            let dashed = input["dashed"]?.boolValue == true ? " (dashed)" : ""
            return latex.isEmpty ? "Added an expression to the graph" : "Added $\(latex)$ to the graph\(dashed)"
        case graphRemoveExpression:
            return "Removed \(input["id"]?.stringValue ?? "an expression") from the graph"
        case graphClear:
            return "Cleared the graph"
        case graphSetViewport:
            let x = "\(Self.number(input["xmin"])) to \(Self.number(input["xmax"]))"
            let y = "\(Self.number(input["ymin"])) to \(Self.number(input["ymax"]))"
            return "Zoomed the graph to x: \(x), y: \(y)"
        case showCalculator:
            return "Opened the calculator"
        case getStudentWork:
            return "Looked at your work"
        default:
            return "Used \(name)"
        }
    }

    private static func number(_ value: JSONValue?) -> String {
        guard let d = value?.doubleValue else { return "?" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        return String(format: "%.3g", d)
    }
}
