import CryptoKit
import Foundation
import XCTest
@testable import ThubanCore

/// Client layer: SSE parsing, request building, retries, OAuth, credentials.
final class AITests: XCTestCase {

    // MARK: SSE parser

    func testSSEParserHandlesAwkwardChunkBoundaries() throws {
        let stream = ": keep-alive comment\r\n"
            + "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\r\n\r\n"
            + "event: ping\ndata: {\"type\": \"ping\"}\n\n"
            + "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
            + "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\ndata: \"delta\":{\"type\":\"text_delta\",\"text\":\"π ≈ 3.14\"}}\n\n"
            + "event: content_block_stop\ndata:{\"type\":\"content_block_stop\",\"index\":0}\n\n"
            + "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":9}}\n\n"
            + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let bytes = Array(stream.utf8)
        // Split points chosen to land inside "\r\n", inside the multi-byte "π" and "≈", and inside field names.
        let piIndex = try XCTUnwrap(stream.utf8.firstIndex(of: 0xCF)).utf16Offset(in: stream)
        let cuts = [5, 27, 28, 60, piIndex + 1, piIndex + 6, bytes.count - 30, bytes.count - 1].sorted()

        var parser = SSEParser()
        var events: [SSEEvent] = []
        var start = 0
        for cut in cuts where cut > start && cut < bytes.count {
            events += parser.feed(Data(bytes[start..<cut]))
            start = cut
        }
        events += parser.feed(Data(bytes[start...]))
        events += parser.finish()

        XCTAssertEqual(events.map(\.event), ["message_start", "ping", "content_block_start", "content_block_delta",
                                             "content_block_stop", "message_delta", "message_stop"])
        XCTAssertTrue(events[3].data.contains("\n\"delta\""), "multi-line data must be joined with a newline")
        XCTAssertEqual(events[4].data, "{\"type\":\"content_block_stop\",\"index\":0}", "data: without a space is valid")

        var decoder = MessagesStreamDecoder()
        var text = ""
        var end: (String, Usage)?
        for event in events {
            for out in try decoder.decode(event) {
                if case .textDelta(let t) = out { text += t }
                if case .messageEnd(let reason, let usage) = out { end = (reason, usage) }
            }
        }
        XCTAssertEqual(text, "π ≈ 3.14")
        XCTAssertEqual(end?.0, "end_turn")
        XCTAssertEqual(end?.1, Usage(inputTokens: 3, outputTokens: 9))
    }

    func testDecoderAccumulatesToolInputJSON() throws {
        let input: JSONValue = ["id": "f", "latex": "y=x^2", "dashed": true, "n": 2.5]
        let stream = SSE.toolUse(text: "Sure.", id: "toolu_9", name: "graph_add_expression", input: input, splitEvery: 3)
        var parser = SSEParser()
        var decoder = MessagesStreamDecoder()
        var events: [StreamEvent] = []
        for sse in parser.feed(Data(stream.utf8)) + parser.finish() { events += try decoder.decode(sse) }

        let deltas = events.compactMap { if case .toolInputDelta(let d) = $0 { return d } else { return nil } }
        XCTAssertGreaterThan(deltas.count, 3)
        XCTAssertEqual(deltas.joined(), input.jsonString())
        guard case .toolUseStart("toolu_9", "graph_add_expression")? = events.first(where: { if case .toolUseStart = $0 { return true } else { return false } }) else {
            return XCTFail("missing toolUseStart")
        }
        let end = events.compactMap { event -> (String, String, JSONValue)? in
            if case let .toolUseEnd(id, name, parsed) = event { return (id, name, parsed) } else { return nil }
        }
        XCTAssertEqual(end.count, 1)
        XCTAssertEqual(end.first?.0, "toolu_9")
        XCTAssertEqual(end.first?.2, input)
        let stop = events.compactMap { if case .messageEnd(let r, _) = $0 { return r } else { return nil } }
        XCTAssertEqual(stop, ["tool_use"])
    }

    func testDecoderMapsErrorEvent() throws {
        var decoder = MessagesStreamDecoder()
        let events = try decoder.decode(SSEEvent(event: "error", data: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
        guard case .error(let error)? = events.first else { return XCTFail("expected error event") }
        XCTAssertEqual(error as? ThubanError, .api(status: 529, message: "Overloaded"))
    }

    // MARK: Request building

    func testRequestBodyAndHeadersWithAPIKey() async throws {
        let transport = MockTransport([.sse(SSE.text("hi"))])
        let client = ClaudeClient.mock(transport, auth: .apiKey("sk-ant-123"))
        let tools = [ToolSpec(name: "t", description: "d", inputSchema: ["type": "object", "properties": [:]])]
        let messages: [ChatMessage] = [
            .user([.image(mediaType: "image/png", base64: "AAAA"), .text("look")]),
            .assistant([.toolUse(id: "tu1", name: "t", input: ["a": 1])]),
            .user([.toolResult(toolUseId: "tu1", content: "ok", isError: false)]),
        ]
        _ = try await client.complete(model: .sonnet, system: "SYS", messages: messages, tools: tools, maxTokens: 300)

        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, ClaudeClient.endpointString)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "accept"), "text/event-stream")

        let body = try transport.body(0)
        XCTAssertEqual(body["model"], "claude-sonnet-5")
        XCTAssertEqual(body["max_tokens"], 300)
        XCTAssertEqual(body["system"], "SYS")
        XCTAssertEqual(body["stream"], true)
        XCTAssertNil(body["thinking"])
        XCTAssertEqual(body["tools"]?[0]?["input_schema"]?["type"], "object")
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["type"], "image")
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["source"]?["media_type"], "image/png")
        XCTAssertEqual(body["messages"]?[0]?["content"]?[0]?["source"]?["type"], "base64")
        XCTAssertEqual(body["messages"]?[1]?["content"]?[0]?["type"], "tool_use")
        XCTAssertEqual(body["messages"]?[1]?["content"]?[0]?["input"]?["a"], 1)
        XCTAssertEqual(body["messages"]?[2]?["content"]?[0]?["tool_use_id"], "tu1")
        XCTAssertNil(body["messages"]?[2]?["content"]?[0]?["is_error"])
    }

    func testRequestHeadersWithOAuthAndThinking() async throws {
        let transport = MockTransport([.sse(SSE.text("hi"))])
        let client = ClaudeClient.mock(transport, auth: .oauth(accessToken: "tok-1"))
        _ = try await client.complete(model: .opus, system: "", messages: [.user("q")], tools: [], maxTokens: 100, thinking: true)

        let request = transport.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

        let body = try transport.body(0)
        XCTAssertEqual(body["thinking"], ["type": "enabled", "budget_tokens": 4000])
        XCTAssertGreaterThan(body["max_tokens"]?.intValue ?? 0, 4000, "max_tokens must exceed the thinking budget")
        XCTAssertNil(body["system"], "empty system is omitted")
        XCTAssertNil(body["tools"], "empty tools are omitted")
    }

    // MARK: Retries & errors

    func testRetriesOn529ThenSucceeds() async throws {
        let transport = MockTransport([
            .json(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, status: 529),
            .json("", status: 503),
            .sse(SSE.text("finally")),
        ])
        let client = ClaudeClient.mock(transport)
        let result = try await client.complete(model: .sonnet, system: "", messages: [.user("x")], tools: [], maxTokens: 10)
        XCTAssertEqual(result.parts, [.text("finally")])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testGivesUpAfterThreeRetryableFailures() async {
        let transport = MockTransport([.json("", status: 529), .json("", status: 529), .json("", status: 529), .sse(SSE.text("no"))])
        let client = ClaudeClient.mock(transport)
        do {
            _ = try await client.complete(model: .sonnet, system: "", messages: [.user("x")], tools: [], maxTokens: 10)
            XCTFail("expected failure")
        } catch let error as ThubanError {
            guard case .api(let status, _) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(status, 529)
        } catch {
            XCTFail("wrong error type \(error)")
        }
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testNonRetryableHTTPErrorMapsToAPIError() async {
        let transport = MockTransport([
            .json(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#, status: 401),
        ])
        let client = ClaudeClient.mock(transport)
        do {
            _ = try await client.complete(model: .sonnet, system: "", messages: [.user("x")], tools: [], maxTokens: 10)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ThubanError, .api(status: 401, message: "invalid x-api-key"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCompleteCollectsTextAndToolUse() async throws {
        let stream = SSE.messageStart()
            + SSE.textBlock(index: 0, pieces: ["Hel", "lo"])
            + SSE.toolUseBlock(index: 1, id: "tu", name: "show_graph", partials: ["{\"mode\":", "\"2d\"}"])
            + SSE.messageEnd(stopReason: "tool_use", outputTokens: 33)
        let client = ClaudeClient.mock(MockTransport([.sse(stream)]))
        let result = try await client.complete(model: .sonnet, system: "", messages: [.user("x")], tools: [], maxTokens: 10)
        XCTAssertEqual(result.parts, [.text("Hello"), .toolUse(id: "tu", name: "show_graph", input: ["mode": "2d"])])
        XCTAssertEqual(result.stopReason, "tool_use")
        XCTAssertEqual(result.usage, Usage(inputTokens: 12, outputTokens: 33))
    }

    // MARK: PKCE / OAuth

    func testPKCEChallengeKnownVector() {
        // RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let fresh = PKCE.makeVerifier()
        XCTAssertEqual(fresh.count, 43)
        XCTAssertNil(fresh.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(PKCE.makeVerifier(), fresh)
    }

    func testBeginBuildsAuthorizeURL() async throws {
        let flow = try OAuthFlow(transport: MockTransport([]))
        let (url, state) = await flow.begin()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.ai")
        XCTAssertEqual(components.path, "/oauth/authorize")
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(query["code"], "true")
        XCTAssertEqual(query["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["redirect_uri"], "https://console.anthropic.com/oauth/code/callback")
        XCTAssertEqual(query["scope"], "org:create_api_key user:profile user:inference")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], state)
        XCTAssertEqual(query["code_challenge"]?.count, 43)
        XCTAssertEqual(Set(query.keys), ["code", "client_id", "response_type", "redirect_uri", "scope", "code_challenge", "code_challenge_method", "state"])
    }

    func testPastedCodeParsingAcceptsThreeForms() throws {
        let plain = try OAuthFlow.parsePastedCode("  abc123  ")
        XCTAssertEqual(plain.code, "abc123")
        XCTAssertNil(plain.state)

        let hashed = try OAuthFlow.parsePastedCode("abc123#st-9")
        XCTAssertEqual(hashed.code, "abc123")
        XCTAssertEqual(hashed.state, "st-9")

        let url = try OAuthFlow.parsePastedCode("https://console.anthropic.com/oauth/code/callback?code=abc123&state=st-9")
        XCTAssertEqual(url.code, "abc123")
        XCTAssertEqual(url.state, "st-9")

        XCTAssertThrowsError(try OAuthFlow.parsePastedCode("   "))
        XCTAssertThrowsError(try OAuthFlow.parsePastedCode("https://example.com/callback?state=only"))
    }

    func testExchangePostsCodeVerifierAndDecodesTokens() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = MockTransport([.json("""
        {"access_token":"acc","refresh_token":"ref","expires_in":3600,"scope":"user:inference user:profile",
         "account":{"email_address":"student@example.edu"}}
        """)])
        let flow = try OAuthFlow(transport: transport, now: { now })
        let (url, state) = await flow.begin()
        let challenge = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code_challenge" }?.value

        let tokens = try await flow.exchange(pastedCode: "the-code#\(state)")
        XCTAssertEqual(tokens, OAuthTokens(accessToken: "acc", refreshToken: "ref", expiresAt: now.addingTimeInterval(3600),
                                           scopes: ["user:inference", "user:profile"], accountEmail: "student@example.edu"))

        let request = transport.requests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://console.anthropic.com/v1/oauth/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        let body = try transport.body(0)
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "the-code")
        XCTAssertEqual(body["state"], .string(state))
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(body["redirect_uri"], "https://console.anthropic.com/oauth/code/callback")
        let verifier = try XCTUnwrap(body["code_verifier"]?.stringValue)
        XCTAssertEqual(PKCE.challenge(for: verifier), challenge)

        // A code from a different attempt is rejected before any request.
        await XCTAssertThrowsErrorAsync(try await flow.exchange(pastedCode: "x#other-state"))
    }

    // MARK: Credential store

    func testCredentialStoreRefreshesTokensThatAreAboutToExpire() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let keychain = InMemoryKeychain()
        let transport = MockTransport([.json(#"{"access_token":"new","expires_in":7200}"#)])
        let flow = try OAuthFlow(transport: transport, now: { now })
        let store = CredentialStore(keychain: keychain, refresher: { try await flow.refresh($0) }, now: { now })

        let stale = OAuthTokens(accessToken: "old", refreshToken: "ref", expiresAt: now.addingTimeInterval(120), scopes: ["user:inference"], accountEmail: "me@x.y")
        try await store.setOAuth(stale)
        XCTAssertEqual(keychain.accounts, ["oauth"])

        let auth = try await store.currentAuth()
        XCTAssertEqual(auth, .oauth(accessToken: "new"))
        XCTAssertEqual(transport.requests.count, 1)
        let body = try transport.body(0)
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["refresh_token"], "ref")
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")

        // Persisted, carrying over the fields the server omitted.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(OAuthTokens.self, from: try XCTUnwrap(keychain.load(account: "oauth")))
        XCTAssertEqual(saved.accessToken, "new")
        XCTAssertEqual(saved.refreshToken, "ref")
        XCTAssertEqual(saved.accountEmail, "me@x.y")
        XCTAssertEqual(saved.expiresAt.timeIntervalSince1970, now.addingTimeInterval(7200).timeIntervalSince1970, accuracy: 1)

        // Second call: fresh token, no new request.
        _ = try await store.currentAuth()
        XCTAssertEqual(transport.requests.count, 1)
        let status = await store.status()
        XCTAssertEqual(status, .oauth(email: "me@x.y", expiresAt: saved.expiresAt))
    }

    func testCredentialStoreFallsBackToAPIKeyAndReportsNotConnected() async throws {
        let keychain = InMemoryKeychain()
        let store = CredentialStore(keychain: keychain, refresher: { $0 })
        var status = await store.status()
        XCTAssertEqual(status, .notConnected)
        await XCTAssertThrowsErrorAsync(try await store.currentAuth()) { XCTAssertEqual($0 as? ThubanError, .notConnected) }

        try await store.setAPIKey(" sk-key \n")
        let auth = try await store.currentAuth()
        XCTAssertEqual(auth, .apiKey("sk-key"))
        status = await store.status()
        XCTAssertEqual(status, .apiKey)

        // A second store over the same keychain sees the key; disconnect clears it.
        let again = CredentialStore(keychain: keychain, refresher: { $0 })
        let loaded = try await again.currentAuth()
        XCTAssertEqual(loaded, .apiKey("sk-key"))
        try await again.disconnect()
        XCTAssertEqual(keychain.accounts, [])
        status = await again.status()
        XCTAssertEqual(status, .notConnected)
    }
}

// MARK: - Async assertion helper

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
