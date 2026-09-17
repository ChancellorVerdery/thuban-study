import Foundation
import os

/// Backoff for retryable HTTP failures (429, 529, 5xx and transport errors before any body byte arrived).
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts including the first one.
    public var maxAttempts: Int
    /// Delay before the second attempt; doubles each time.
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Fraction of the delay randomised in both directions (0.25 ⇒ ±25 %).
    public var jitter: Double

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8, jitter: Double = 0.25) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitter = min(1, max(0, jitter))
    }

    public static let `default` = RetryPolicy()
    /// Three attempts with no waiting; for tests.
    public static let immediate = RetryPolicy(baseDelay: 0, maxDelay: 0, jitter: 0)

    /// Jittered delay before attempt `attempt` (2-based). A `Retry-After` header wins when it is present.
    public func delay(beforeAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, maxDelay) }
        let exponent = max(0, attempt - 2)
        let nominal = min(maxDelay, baseDelay * pow(2, Double(exponent)))
        guard jitter > 0, nominal > 0 else { return nominal }
        let factor = 1 + Double.random(in: -jitter...jitter)
        return nominal * factor
    }
}

/// Streaming client for the Anthropic Messages API. Auth is fetched per attempt from `authProvider`
/// (so a refreshed OAuth token is picked up automatically); the transport is injectable for tests.
public actor ClaudeClient {
    public static let apiVersion = "2023-06-01"
    public static let oauthBeta = "oauth-2025-04-20"
    /// Claude account (OAuth) tokens are Claude Code credentials: the API only serves them when the system prompt
    /// opens with this sentence and answers every other request with `429 rate_limit_error`. It is prepended to
    /// the agents' own prompts on OAuth requests; API-key requests are sent as-is.
    public static let oauthSystemPrefix = "You are Claude Code, Anthropic's official CLI for Claude."
    public static let endpointString = "https://api.anthropic.com/v1/messages"
    /// Budget passed as `thinking.budget_tokens` when thinking is enabled.
    public static let thinkingBudget = 4000

    private let authProvider: @Sendable () async throws -> ClaudeAuth
    private let transport: ClaudeTransport
    private let retryPolicy: RetryPolicy
    private let endpoint: URL?
    private let logger = Logger(subsystem: "com.thuban.study", category: "ClaudeClient")

    public init(
        authProvider: @escaping @Sendable () async throws -> ClaudeAuth,
        transport: ClaudeTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .default,
        endpoint: URL? = nil
    ) {
        self.authProvider = authProvider
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.endpoint = endpoint
    }

    // MARK: Public API

    /// Streams one assistant turn. The stream ends with `.messageEnd` on success, or throws a `ThubanError`.
    public nonisolated func stream(
        model: ClaudeModel,
        system: String,
        messages: [ChatMessage],
        tools: [ToolSpec],
        maxTokens: Int,
        thinking: Bool,
        toolChoice: ToolChoice? = nil
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let spec = RequestSpec(
            model: model, system: system, messages: messages, tools: tools,
            maxTokens: maxTokens, thinking: thinking, toolChoice: toolChoice
        )
        return AsyncThrowingStream { continuation in
            let task = Task { await self.run(spec, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience: collects the stream into content parts.
    public func complete(
        model: ClaudeModel,
        system: String,
        messages: [ChatMessage],
        tools: [ToolSpec] = [],
        maxTokens: Int = 4096,
        thinking: Bool = false,
        toolChoice: ToolChoice? = nil
    ) async throws -> (parts: [ContentPart], stopReason: String, usage: Usage) {
        var collector = PartsCollector()
        var stopReason = "end_turn"
        var usage = Usage()
        let events = stream(
            model: model, system: system, messages: messages, tools: tools,
            maxTokens: maxTokens, thinking: thinking, toolChoice: toolChoice
        )
        for try await event in events {
            switch event {
            case .textDelta(let text): collector.appendText(text)
            case .toolUseEnd(let id, let name, let input): collector.appendToolUse(id: id, name: name, input: input)
            case .messageEnd(let reason, let u):
                stopReason = reason
                usage = u
            case .toolUseStart, .toolInputDelta, .error: break
            }
        }
        return (collector.parts, stopReason, usage)
    }

    // MARK: Request building

    struct RequestSpec: Sendable {
        var model: ClaudeModel
        var system: String
        var messages: [ChatMessage]
        var tools: [ToolSpec]
        var maxTokens: Int
        var thinking: Bool
        var toolChoice: ToolChoice?
    }

    private struct Body: Encodable {
        struct Thinking: Encodable {
            let type = "enabled"
            let budgetTokens: Int
            enum CodingKeys: String, CodingKey { case type, budgetTokens = "budget_tokens" }
        }

        var model: String
        var maxTokens: Int
        var system: String?
        var messages: [ChatMessage]
        var tools: [ToolSpec]?
        var toolChoice: JSONValue?
        var stream: Bool
        var thinking: Thinking?

        enum CodingKeys: String, CodingKey {
            case model, maxTokens = "max_tokens", system, messages, tools, toolChoice = "tool_choice", stream, thinking
        }
    }

    /// Builds the signed request. Internal so tests can inspect it without a transport.
    nonisolated func makeRequest(_ spec: RequestSpec, auth: ClaudeAuth) throws -> URLRequest {
        guard let url = endpoint ?? URL(string: Self.endpointString) else {
            throw ThubanError.network("Invalid Messages API endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        switch auth {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.oauthBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try encodeBody(spec, auth: auth)
        return request
    }

    /// The system prompt actually sent: the agent's prompt, behind the Claude Code sentinel for OAuth tokens.
    nonisolated static func systemPrompt(_ system: String, auth: ClaudeAuth) -> String? {
        switch auth {
        case .apiKey: return system.isEmpty ? nil : system
        case .oauth: return system.isEmpty ? oauthSystemPrefix : oauthSystemPrefix + "\n\n" + system
        }
    }

    private nonisolated func encodeBody(_ spec: RequestSpec, auth: ClaudeAuth) throws -> Data {
        // The API requires max_tokens to exceed the thinking budget.
        let maxTokens = spec.thinking ? max(spec.maxTokens, Self.thinkingBudget + 1024) : spec.maxTokens
        let body = Body(
            model: spec.model.rawValue,
            maxTokens: maxTokens,
            system: Self.systemPrompt(spec.system, auth: auth),
            messages: spec.messages,
            tools: spec.tools.isEmpty ? nil : spec.tools,
            toolChoice: spec.thinking ? nil : spec.toolChoice?.jsonValue,
            stream: true,
            thinking: spec.thinking ? Body.Thinking(budgetTokens: Self.thinkingBudget) : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(body)
        } catch {
            throw ThubanError.parse("Could not encode the request: \(error.localizedDescription)")
        }
    }

    // MARK: Execution

    private func run(_ spec: RequestSpec, into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async {
        do {
            let body = try await open(spec)
            try await pump(body, into: continuation)
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.normalize(error))
        }
    }

    /// Sends the request, retrying retryable failures, and returns the body stream of a 2xx response.
    private func open(_ spec: RequestSpec) async throws -> AsyncThrowingStream<Data, Error> {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let request = try makeRequest(spec, auth: try await authProvider())
            let failure: ThubanError
            var retryAfter: TimeInterval?
            do {
                let (body, response) = try await transport.send(request)
                if (200..<300).contains(response.statusCode) { return body }
                failure = await Self.apiError(status: response.statusCode, body: body)
                retryAfter = Self.retryAfter(response)
            } catch let error as ThubanError {
                failure = error
            } catch {
                failure = Self.normalize(error)
            }
            guard failure.isRetryable, attempt < retryPolicy.maxAttempts else { throw failure }
            let delay = retryPolicy.delay(beforeAttempt: attempt + 1, retryAfter: retryAfter)
            logger.info("Retrying after \(failure.localizedDescription, privacy: .public) in \(delay, privacy: .public)s")
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            attempt += 1
        }
    }

    private func pump(
        _ body: AsyncThrowingStream<Data, Error>,
        into continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        var parser = SSEParser()
        var decoder = MessagesStreamDecoder()
        for try await chunk in body {
            try Task.checkCancellation()
            for sse in parser.feed(chunk) { try Self.forward(try decoder.decode(sse), to: continuation) }
        }
        for sse in parser.finish() { try Self.forward(try decoder.decode(sse), to: continuation) }
    }

    private static func forward(
        _ events: [StreamEvent],
        to continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) throws {
        for event in events {
            continuation.yield(event)
            if case .error(let error) = event { throw error }
        }
    }

    // MARK: Errors

    private static func apiError(status: Int, body: AsyncThrowingStream<Data, Error>) async -> ThubanError {
        let data = (try? await body.collect()) ?? Data()
        let message = (try? JSONValue(data: data))?["error"]?["message"]?.stringValue
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        return .api(status: status, message: message.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : message)
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after") else { return nil }
        return TimeInterval(raw.trimmingCharacters(in: .whitespaces))
    }

    /// Wraps any error into a `ThubanError`.
    static func normalize(_ error: Error) -> ThubanError {
        switch error {
        case let e as ThubanError: return e
        case is CancellationError: return .cancelled
        case let e as DecodingError: return .parse(String(describing: e))
        case let e as URLError where e.code == .cancelled: return .cancelled
        default: return .network(error.localizedDescription)
        }
    }
}

/// Merges streamed deltas into content parts, keeping tool-use blocks in order.
struct PartsCollector {
    private(set) var parts: [ContentPart] = []

    mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(let existing)? = parts.last {
            parts[parts.count - 1] = .text(existing + text)
        } else {
            parts.append(.text(text))
        }
    }

    mutating func appendToolUse(id: String, name: String, input: JSONValue) {
        parts.append(.toolUse(id: id, name: name, input: input))
    }

    /// Parts with empty text blocks dropped (the API rejects them in assistant turns).
    var nonEmptyParts: [ContentPart] {
        parts.filter { part in
            if case .text(let t) = part { return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }
    }
}
