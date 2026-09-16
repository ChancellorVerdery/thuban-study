import Foundation
import XCTest
@testable import ThubanCore

/// Scripted transport: hands out queued responses in order and records every request.
final class MockTransport: ClaudeTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var chunks: [Data]
        var headers: [String: String] = [:]

        static func sse(_ text: String, status: Int = 200) -> Response {
            Response(status: status, chunks: [Data(text.utf8)])
        }

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, chunks: [Data(text.utf8)], headers: ["content-type": "application/json"])
        }
    }

    private let lock = NSLock()
    private var queue: [Response]
    private var recorded: [URLRequest] = []

    init(_ responses: [Response]) {
        self.queue = responses
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let next: Response? = lock.withLock {
            recorded.append(request)
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let response = next else { throw ThubanError.network("MockTransport: no response queued") }
        let url = request.url ?? URL(fileURLWithPath: "/")
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in response.chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return (stream, http)
    }

    /// The JSON body of request `index`.
    func body(_ index: Int) throws -> JSONValue {
        let request = requests[index]
        return try JSONValue(data: try XCTUnwrap(request.httpBody))
    }
}

/// Builders for Messages API server-sent event streams.
enum SSE {
    static func event(_ name: String, _ json: String) -> String {
        "event: \(name)\ndata: \(json)\n\n"
    }

    static func messageStart(inputTokens: Int = 12) -> String {
        event("message_start", """
        {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5",\
        "content":[],"stop_reason":null,"usage":{"input_tokens":\(inputTokens),"output_tokens":1}}}
        """)
    }

    static func textBlock(index: Int, pieces: [String]) -> String {
        var s = event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
        for piece in pieces {
            s += event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(JSONValue.string(piece).jsonString())}}"#)
        }
        s += event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
        return s
    }

    static func toolUseBlock(index: Int, id: String, name: String, partials: [String]) -> String {
        var s = event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}}"#)
        for partial in partials {
            s += event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"input_json_delta","partial_json":\#(JSONValue.string(partial).jsonString())}}"#)
        }
        s += event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
        return s
    }

    static func messageEnd(stopReason: String, outputTokens: Int = 20) -> String {
        event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)","stop_sequence":null},"usage":{"output_tokens":\#(outputTokens)}}"#)
            + event("message_stop", #"{"type":"message_stop"}"#)
    }

    /// A complete text-only reply.
    static func text(_ text: String, inputTokens: Int = 12, outputTokens: Int = 20) -> String {
        messageStart(inputTokens: inputTokens)
            + textBlock(index: 0, pieces: [text])
            + messageEnd(stopReason: "end_turn", outputTokens: outputTokens)
    }

    /// A reply that (optionally) says something, then calls one tool with the given JSON input.
    static func toolUse(text: String? = nil, id: String, name: String, input: JSONValue, splitEvery: Int = 7) -> String {
        var s = messageStart()
        var index = 0
        if let text {
            s += textBlock(index: index, pieces: [text])
            index += 1
        }
        let json = input.jsonString()
        let partials = stride(from: 0, to: json.count, by: splitEvery).map { offset -> String in
            let start = json.index(json.startIndex, offsetBy: offset)
            let end = json.index(start, offsetBy: min(splitEvery, json.count - offset))
            return String(json[start..<end])
        }
        s += toolUseBlock(index: index, id: id, name: name, partials: partials)
        s += messageEnd(stopReason: "tool_use")
        return s
    }
}

/// Records tool calls and answers with a fixed result.
final class RecordingToolHandler: TutorToolHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(name: String, input: JSONValue)] = []
    let result: JSONValue

    init(result: JSONValue = ["ok": true]) {
        self.result = result
    }

    var calls: [(name: String, input: JSONValue)] { lock.withLock { recorded } }

    func handle(name: String, input: JSONValue) async -> JSONValue {
        lock.withLock { recorded.append((name, input)) }
        return result
    }
}

/// Thread-safe progress recorder.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ImportProgress] = []

    func record(_ p: ImportProgress) { lock.withLock { items.append(p) } }
    var all: [ImportProgress] { lock.withLock { items } }
}

extension ClaudeClient {
    /// A client that always authenticates with a fixed API key.
    static func mock(_ transport: ClaudeTransport, auth: ClaudeAuth = .apiKey("sk-test")) -> ClaudeClient {
        ClaudeClient(authProvider: { auth }, transport: transport, retryPolicy: .immediate)
    }
}
