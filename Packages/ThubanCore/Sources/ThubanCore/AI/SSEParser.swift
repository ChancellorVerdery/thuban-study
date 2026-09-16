import Foundation

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
    /// The `event:` field, if any.
    public var event: String?
    /// The `data:` lines joined with `\n`.
    public var data: String
    /// The last `id:` seen.
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental parser for the `text/event-stream` format. Feed it byte chunks split anywhere (mid-line, mid-UTF-8
/// sequence, between `\r` and `\n`) and it yields complete events. Comment lines (`:…`) and `retry:` are ignored;
/// multi-line `data:` fields are joined with newlines as the spec requires.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []
    private var lastId: String?

    public init() {}

    /// Consumes a chunk and returns every event completed by it.
    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        return process(lines: extractLines(final: false))
    }

    /// Flushes whatever remains at end of stream (a trailing event without a blank line is still dispatched).
    public mutating func finish() -> [SSEEvent] {
        var events = process(lines: extractLines(final: true))
        if let pending = dispatch() { events.append(pending) }
        return events
    }

    // MARK: Lines

    private mutating func extractLines(final: Bool) -> [String] {
        var lines: [String] = []
        var start = buffer.startIndex
        var i = start
        while i < buffer.endIndex {
            let byte = buffer[i]
            guard byte == 0x0A || byte == 0x0D else {
                i += 1
                continue
            }
            var next = i + 1
            if byte == 0x0D {
                if next < buffer.endIndex {
                    if buffer[next] == 0x0A { next += 1 }
                } else if !final {
                    break // a `\n` may still follow this `\r` in the next chunk
                }
            }
            lines.append(String(decoding: buffer[start..<i], as: UTF8.self))
            start = next
            i = next
        }
        if final, start < buffer.endIndex {
            lines.append(String(decoding: buffer[start...], as: UTF8.self))
            start = buffer.endIndex
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        return lines
    }

    private mutating func process(lines: [String]) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for line in lines {
            if line.isEmpty {
                if let event = dispatch() { events.append(event) }
            } else if line.hasPrefix(":") {
                continue
            } else {
                handle(field: line)
            }
        }
        return events
    }

    private mutating func handle(field line: String) {
        let name: Substring
        let value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.first == " " { v = v.dropFirst() }
            value = v
        } else {
            name = line[...]
            value = ""
        }
        switch name {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": lastId = String(value)
        default: break // "retry" and unknown fields are ignored
        }
    }

    /// Builds the pending event and resets the field buffers; `nil` when no data was collected.
    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"), id: lastId)
    }
}

/// Turns the Messages API's SSE events into `StreamEvent`s, accumulating `input_json_delta`s per tool-use block
/// and token usage across `message_start` / `message_delta`.
public struct MessagesStreamDecoder: Sendable {
    private struct Block {
        var type: String
        var id: String
        var name: String
        var json: String
    }

    private var blocks: [Int: Block] = [:]
    private var usage = Usage()
    private var stopReason = ""

    public init() {}

    /// Decodes one SSE event. Throws `ThubanError.parse` for malformed JSON.
    public mutating func decode(_ event: SSEEvent) throws -> [StreamEvent] {
        let payload: JSONValue
        do {
            payload = try JSONValue(jsonString: event.data)
        } catch {
            throw ThubanError.parse("Malformed event payload: \(event.data.prefix(120))")
        }
        let type = event.event ?? payload["type"]?.stringValue ?? ""
        switch type {
        case "message_start": return handleMessageStart(payload)
        case "content_block_start": return handleBlockStart(payload)
        case "content_block_delta": return handleBlockDelta(payload)
        case "content_block_stop": return try handleBlockStop(payload)
        case "message_delta": return handleMessageDelta(payload)
        case "message_stop": return [.messageEnd(stopReason: stopReason, usage: usage)]
        case "error": return [.error(Self.apiError(from: payload))]
        default: return [] // ping and future event types
        }
    }

    private mutating func handleMessageStart(_ payload: JSONValue) -> [StreamEvent] {
        if let input = payload["message"]?["usage"]?["input_tokens"]?.intValue { usage.inputTokens = input }
        if let output = payload["message"]?["usage"]?["output_tokens"]?.intValue { usage.outputTokens = output }
        return []
    }

    private mutating func handleBlockStart(_ payload: JSONValue) -> [StreamEvent] {
        guard let index = payload["index"]?.intValue, let block = payload["content_block"] else { return [] }
        let type = block["type"]?.stringValue ?? "text"
        let id = block["id"]?.stringValue ?? ""
        let name = block["name"]?.stringValue ?? ""
        blocks[index] = Block(type: type, id: id, name: name, json: "")
        switch type {
        case "tool_use":
            return [.toolUseStart(id: id, name: name)]
        case "text":
            let initial = block["text"]?.stringValue ?? ""
            return initial.isEmpty ? [] : [.textDelta(initial)]
        default:
            return []
        }
    }

    private mutating func handleBlockDelta(_ payload: JSONValue) -> [StreamEvent] {
        guard let index = payload["index"]?.intValue, let delta = payload["delta"] else { return [] }
        switch delta["type"]?.stringValue {
        case "text_delta":
            return [.textDelta(delta["text"]?.stringValue ?? "")]
        case "input_json_delta":
            let partial = delta["partial_json"]?.stringValue ?? ""
            blocks[index]?.json += partial
            return [.toolInputDelta(partial)]
        default:
            return [] // thinking_delta / signature_delta are consumed silently
        }
    }

    private mutating func handleBlockStop(_ payload: JSONValue) throws -> [StreamEvent] {
        guard let index = payload["index"]?.intValue, let block = blocks.removeValue(forKey: index) else { return [] }
        guard block.type == "tool_use" else { return [] }
        let text = block.json.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: JSONValue
        if text.isEmpty {
            input = .object([:])
        } else {
            do {
                input = try JSONValue(jsonString: text)
            } catch {
                throw ThubanError.parse("Tool '\(block.name)' produced invalid JSON input.")
            }
        }
        return [.toolUseEnd(id: block.id, name: block.name, input: input)]
    }

    private mutating func handleMessageDelta(_ payload: JSONValue) -> [StreamEvent] {
        if let reason = payload["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
        if let output = payload["usage"]?["output_tokens"]?.intValue { usage.outputTokens = output }
        if let input = payload["usage"]?["input_tokens"]?.intValue { usage.inputTokens = input }
        return []
    }

    /// Maps an `error` event to `ThubanError.api` using the API's error type names.
    static func apiError(from payload: JSONValue) -> ThubanError {
        let error = payload["error"] ?? payload
        let type = error["type"]?.stringValue ?? "api_error"
        let message = error["message"]?.stringValue ?? "Unknown error"
        return ThubanError.api(status: status(forErrorType: type), message: message)
    }

    static func status(forErrorType type: String) -> Int {
        switch type {
        case "invalid_request_error": return 400
        case "authentication_error": return 401
        case "permission_error": return 403
        case "not_found_error": return 404
        case "request_too_large": return 413
        case "rate_limit_error": return 429
        case "overloaded_error": return 529
        default: return 500
        }
    }
}
