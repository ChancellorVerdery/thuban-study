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

    func testDecoderDropsToolBlockCutOffByMaxTokens() throws {
        let truncated = SSE.messageStart()
            + SSE.toolUseBlock(index: 0, id: "toolu_1", name: "emit_questions", partials: [#"{"questions":[{"stem":"Le"#])
            + SSE.messageEnd(stopReason: "max_tokens")
        var parser = SSEParser()
        var decoder = MessagesStreamDecoder()
        var events: [StreamEvent] = []
        for sse in parser.feed(Data(truncated.utf8)) + parser.finish() { events += try decoder.decode(sse) }
        XCTAssertFalse(events.contains { if case .toolUseEnd = $0 { return true } else { return false } }, "a cut-off tool block is dropped")
        let stop = events.compactMap { if case .messageEnd(let r, _) = $0 { return r } else { return nil } }
        XCTAssertEqual(stop, ["max_tokens"])

        // The same broken JSON with a normal stop reason is still a parse error.
        let broken = SSE.messageStart()
            + SSE.toolUseBlock(index: 0, id: "toolu_2", name: "emit_questions", partials: [#"{"questions":[{"stem":"Le"#])
            + SSE.messageEnd(stopReason: "tool_use")
        var parser2 = SSEParser()
        var decoder2 = MessagesStreamDecoder()
        XCTAssertThrowsError(try (parser2.feed(Data(broken.utf8)) + parser2.finish()).forEach { _ = try decoder2.decode($0) }) { error in
            guard case .parse(let detail)? = error as? ThubanError else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(detail.contains("emit_questions"))
        }
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
        XCTAssertEqual(body["system"]?[0]?["text"]?.stringValue, ClaudeClient.oauthSystemPrefix,
                       "OAuth requests always carry the Claude Code sentinel block, even with an empty prompt")
        XCTAssertNil(body["system"]?[1], "no second block for an empty prompt")
        XCTAssertNil(body["tools"], "empty tools are omitted")
    }

    func testOAuthPrefixesSystemPromptAndAPIKeyDoesNot() async throws {
        let oauthTransport = MockTransport([.sse(SSE.text("hi"))])
        let oauthClient = ClaudeClient.mock(oauthTransport, auth: .oauth(accessToken: "tok-1"))
        _ = try await oauthClient.complete(model: .sonnet, system: "Tutor rules", messages: [.user("q")])
        let oauthSystem = try oauthTransport.body(0)["system"]
        XCTAssertEqual(oauthSystem?[0]?["type"]?.stringValue, "text")
        XCTAssertEqual(oauthSystem?[0]?["text"]?.stringValue, ClaudeClient.oauthSystemPrefix,
                       "the sentinel must be its own first block; a string prefix is refused by the API")
        XCTAssertEqual(oauthSystem?[1]?["text"]?.stringValue, "Tutor rules")
        XCTAssertNil(oauthSystem?[2])

        let keyTransport = MockTransport([.sse(SSE.text("hi"))])
        let keyClient = ClaudeClient.mock(keyTransport, auth: .apiKey("sk-ant-123"))
        _ = try await keyClient.complete(model: .sonnet, system: "Tutor rules", messages: [.user("q")])
        XCTAssertEqual(try keyTransport.body(0)["system"]?.stringValue, "Tutor rules")
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

    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func staleTokens(expiringIn seconds: TimeInterval = 120) -> OAuthTokens {
        OAuthTokens(accessToken: "old", refreshToken: "ref", expiresAt: Self.epoch.addingTimeInterval(seconds),
                    scopes: ["user:inference"], accountEmail: "me@x.y")
    }

    func testRefusedRefreshMarksTheSignInExpired() async throws {
        let keychain = InMemoryKeychain()
        let transport = MockTransport([.json(#"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#, status: 400)])
        let flow = try OAuthFlow(transport: transport, now: { Self.epoch })
        let store = CredentialStore(keychain: keychain, refresher: { try await flow.refresh($0) }, now: { Self.epoch })
        try await store.setOAuth(staleTokens())

        await XCTAssertThrowsErrorAsync(try await store.currentAuth()) { XCTAssertEqual($0 as? ThubanError, .sessionExpired) }
        XCTAssertTrue(ThubanError.sessionExpired.isAuthFailure)
        XCTAssertTrue(ThubanError.api(status: 401, message: "x").isAuthFailure)
        XCTAssertTrue(ThubanError.api(status: 403, message: "x").isAuthFailure)
        XCTAssertFalse(ThubanError.api(status: 500, message: "x").isAuthFailure)
        XCTAssertTrue(ThubanError.keychainDenied("x").isCredentialProblem)

        // Stays expired (no second refresh attempt) until the student signs in again or disconnects.
        var status = await store.status()
        XCTAssertEqual(status, .oauthExpired(email: "me@x.y"))
        XCTAssertFalse(status.isConnected)
        XCTAssertTrue(status.needsAttention)
        await XCTAssertThrowsErrorAsync(try await store.currentAuth()) { XCTAssertEqual($0 as? ThubanError, .sessionExpired) }
        XCTAssertEqual(transport.requests.count, 1)

        try await store.setOAuth(staleTokens(expiringIn: 7200))
        status = await store.status()
        XCTAssertEqual(status, .oauth(email: "me@x.y", expiresAt: Self.epoch.addingTimeInterval(7200)))
        let auth = try await store.currentAuth()
        XCTAssertEqual(auth, .oauth(accessToken: "old"))
    }

    func testAPIRejectionMarksTheSignInExpired() async throws {
        let store = CredentialStore(keychain: InMemoryKeychain(), refresher: { $0 }, now: { Self.epoch })
        try await store.setOAuth(staleTokens(expiringIn: 7200))
        await store.noteAuthenticationFailure()
        let status = await store.status()
        XCTAssertEqual(status, .oauthExpired(email: "me@x.y"))
        await XCTAssertThrowsErrorAsync(try await store.currentAuth()) { XCTAssertEqual($0 as? ThubanError, .sessionExpired) }
        try await store.disconnect()
        let after = await store.status()
        XCTAssertEqual(after, .notConnected)
    }

    func testDisconnectDuringRefreshDoesNotResurrectTokens() async throws {
        let keychain = InMemoryKeychain()
        let gate = Gate()
        let store = CredentialStore(keychain: keychain, refresher: { tokens in
            await gate.wait()
            return OAuthTokens(accessToken: "new", refreshToken: "ref2", expiresAt: Self.epoch.addingTimeInterval(7200))
        }, now: { Self.epoch })
        try await store.setOAuth(staleTokens())

        let refreshing = Task { try await store.currentAuth() }
        await gate.waitForWaiter()
        try await store.disconnect()
        await gate.open()

        await XCTAssertThrowsErrorAsync(try await refreshing.value) { XCTAssertEqual($0 as? ThubanError, .notConnected) }
        XCTAssertEqual(keychain.accounts, [])
        let status = await store.status()
        XCTAssertEqual(status, .notConnected)
    }

    func testJoinedCallersShareTheRefreshOutcome() async throws {
        let gate = Gate()
        let store = CredentialStore(keychain: InMemoryKeychain(), refresher: { _ in
            await gate.wait()
            throw URLError(.notConnectedToInternet)
        }, now: { Self.epoch })
        try await store.setOAuth(staleTokens())

        let first = Task { try await store.currentAuth() }
        await gate.waitForWaiter()
        let second = Task { try await store.currentAuth() }
        // Let the second caller join the in-flight task before the failure lands.
        try await Task.sleep(nanoseconds: 50_000_000)
        await gate.open()

        // Transient failure while the old token is still valid: both callers get the old token.
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a, .oauth(accessToken: "old"))
        XCTAssertEqual(b, .oauth(accessToken: "old"))
        let calls = await gate.waiterCount
        XCTAssertEqual(calls, 1, "one shared refresh")
    }

    func testRefreshedTokensSurviveAKeychainWriteFailure() async throws {
        let keychain = FlakyKeychain()
        let store = CredentialStore(keychain: keychain, refresher: { old in
            OAuthTokens(accessToken: "new", refreshToken: "ref2", expiresAt: Self.epoch.addingTimeInterval(7200),
                        scopes: old.scopes, accountEmail: old.accountEmail)
        }, now: { Self.epoch })
        try await store.setOAuth(staleTokens())
        keychain.failSaves = true

        let auth = try await store.currentAuth()
        XCTAssertEqual(auth, .oauth(accessToken: "new"), "the rotated tokens are used even though the Keychain write failed")
        let status = await store.status()
        XCTAssertEqual(status, .oauth(email: "me@x.y", expiresAt: Self.epoch.addingTimeInterval(7200)))

        // Nothing was lost: the old record is still on disk and the new one lives in memory.
        let again = try await store.currentAuth()
        XCTAssertEqual(again, .oauth(accessToken: "new"))
    }

    func testDisconnectClearsEverythingItCanAndRethrows() async throws {
        let keychain = FlakyKeychain()
        let store = CredentialStore(keychain: keychain, refresher: { $0 }, now: { Self.epoch })
        try await store.setOAuth(staleTokens(expiringIn: 7200))
        try await store.setAPIKey("sk-key")
        keychain.failDeletes = ["oauth"]

        await XCTAssertThrowsErrorAsync(try await store.disconnect())
        XCTAssertEqual(keychain.inner.accounts, ["oauth"], "the delete that could run did run")
        // The status reflects what is really left, not the credentials that were meant to go.
        let status = await store.status()
        XCTAssertEqual(status, .oauth(email: "me@x.y", expiresAt: Self.epoch.addingTimeInterval(7200)))

        keychain.failDeletes = []
        try await store.disconnect()
        let after = await store.status()
        XCTAssertEqual(after, .notConnected)
    }

    func testKeychainDenialIsReportedAsSuch() async throws {
        let keychain = FlakyKeychain()
        try keychain.inner.save(Data("sk-key".utf8), account: "apikey")
        keychain.denyLoads = true
        let store = CredentialStore(keychain: keychain, refresher: { $0 }, now: { Self.epoch })

        await XCTAssertThrowsErrorAsync(try await store.currentAuth()) {
            XCTAssertEqual($0 as? ThubanError, .keychainDenied("denied"))
        }
        var status = await store.status()
        XCTAssertEqual(status, .keychainDenied("denied"))
        XCTAssertTrue(status.needsAttention)

        // The student allowed access on the next prompt.
        keychain.denyLoads = false
        let auth = try await store.currentAuth()
        XCTAssertEqual(auth, .apiKey("sk-key"))
        status = await store.status()
        XCTAssertEqual(status, .apiKey)
    }
}

// MARK: - Test doubles

/// A one-shot latch: `wait()` suspends until `open()`; the test can see how many callers are parked.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiterCount = 0

    func wait() async {
        waiterCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters = []
        parked.forEach { $0.resume() }
    }

    func waitForWaiter() async {
        while waiterCount == 0 { await Task.yield() }
    }
}

/// In-memory keychain whose failures the test switches on and off.
private final class FlakyKeychain: KeychainStorage, @unchecked Sendable {
    let inner = InMemoryKeychain()
    private let lock = NSLock()
    private var _failSaves = false
    private var _denyLoads = false
    private var _failDeletes: Set<String> = []

    var failSaves: Bool {
        get { lock.withLock { _failSaves } }
        set { lock.withLock { _failSaves = newValue } }
    }
    var denyLoads: Bool {
        get { lock.withLock { _denyLoads } }
        set { lock.withLock { _denyLoads = newValue } }
    }
    var failDeletes: Set<String> {
        get { lock.withLock { _failDeletes } }
        set { lock.withLock { _failDeletes = newValue } }
    }

    func save(_ data: Data, account: String) throws {
        if failSaves { throw ThubanError.store("Keychain save failed: User interaction is not allowed.") }
        try inner.save(data, account: account)
    }

    func load(account: String) throws -> Data? {
        if denyLoads { throw ThubanError.keychainDenied("denied") }
        return try inner.load(account: account)
    }

    func delete(account: String) throws {
        if failDeletes.contains(account) { throw ThubanError.store("Keychain delete failed: \(account)") }
        try inner.delete(account: account)
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
