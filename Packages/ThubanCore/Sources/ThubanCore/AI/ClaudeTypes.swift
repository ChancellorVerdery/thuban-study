import Foundation

/// How a Messages API request is authenticated.
public enum ClaudeAuth: Sendable, Equatable {
    /// A Claude.ai OAuth access token (sent as `Authorization: Bearer …` with the OAuth beta header).
    case oauth(accessToken: String)
    /// A console API key (sent as `x-api-key`).
    case apiKey(String)
}

/// Token accounting for one response (summed across rounds by the agents).
public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let zero = Usage()

    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        Usage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }

    public static func += (lhs: inout Usage, rhs: Usage) { lhs = lhs + rhs }
}

/// One turn of a Messages API conversation. `role` is `"user"` or `"assistant"`.
public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: [ContentPart]

    public init(role: String, content: [ContentPart]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: [.text(text)]) }
    public static func user(_ parts: [ContentPart]) -> ChatMessage { ChatMessage(role: "user", content: parts) }
    public static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", content: [.text(text)]) }
    public static func assistant(_ parts: [ContentPart]) -> ChatMessage { ChatMessage(role: "assistant", content: parts) }
}

/// A content block. Encodes to and decodes from the Messages API wire format
/// (`{"type":"text",…}`, `{"type":"image","source":{…}}`, `{"type":"tool_use",…}`, `{"type":"tool_result",…}`).
public enum ContentPart: Codable, Sendable, Equatable {
    case text(String)
    case image(mediaType: String, base64: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, text, source, id, name, input, toolUseId = "tool_use_id", content, isError = "is_error"
    }

    private enum SourceKeys: String, CodingKey { case type, mediaType = "media_type", data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            let s = try c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            self = .image(
                mediaType: try s.decodeIfPresent(String.self, forKey: .mediaType) ?? "image/png",
                base64: try s.decodeIfPresent(String.self, forKey: .data) ?? ""
            )
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .object([:])
            )
        case "tool_result":
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try Self.decodeResultContent(c),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown content type '\(type)'")
        }
    }

    /// `tool_result.content` may be a plain string or an array of text blocks.
    private static func decodeResultContent(_ c: KeyedDecodingContainer<CodingKeys>) throws -> String {
        if let s = try? c.decode(String.self, forKey: .content) { return s }
        if let parts = try? c.decode([ContentPart].self, forKey: .content) {
            return parts.compactMap(\.textValue).joined(separator: "\n")
        }
        return ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case let .image(mediaType, base64):
            try c.encode("image", forKey: .type)
            var s = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try s.encode("base64", forKey: .type)
            try s.encode(mediaType, forKey: .mediaType)
            try s.encode(base64, forKey: .data)
        case let .toolUse(id, name, input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case let .toolResult(toolUseId, content, isError):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            if isError { try c.encode(true, forKey: .isError) }
        }
    }

    /// The text of a `.text` part, else `nil`.
    public var textValue: String? { if case .text(let t) = self { return t } else { return nil } }

    /// The `(id, name, input)` of a `.toolUse` part, else `nil`.
    public var toolUseValue: (id: String, name: String, input: JSONValue)? {
        if case let .toolUse(id, name, input) = self { return (id, name, input) } else { return nil }
    }
}

/// A tool definition as sent in the request's `tools` array.
public struct ToolSpec: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema = "input_schema" }
}

/// How the model must choose tools for a request (`tool_choice`).
public enum ToolChoice: Sendable, Equatable {
    case auto
    case any
    case tool(name: String)

    var jsonValue: JSONValue {
        switch self {
        case .auto: return ["type": "auto"]
        case .any: return ["type": "any"]
        case .tool(let name): return ["type": "tool", "name": .string(name)]
        }
    }
}

/// Events yielded by `ClaudeClient.stream`.
public enum StreamEvent: Sendable {
    case textDelta(String)
    case toolUseStart(id: String, name: String)
    case toolInputDelta(String)
    /// The tool's complete input, parsed from the accumulated `input_json_delta`s.
    case toolUseEnd(id: String, name: String, input: JSONValue)
    case messageEnd(stopReason: String, usage: Usage)
    /// An `error` SSE event from the API; the stream finishes throwing the same error right after.
    case error(Error)
}
