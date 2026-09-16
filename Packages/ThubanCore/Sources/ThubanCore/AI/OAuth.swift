import CryptoKit
import Foundation

/// Endpoints and client identity for the personal-use OAuth flow (mirrors the Claude Code CLI).
public struct OAuthConfig: Sendable, Equatable {
    public var clientId: String
    public var authorizeURL: String
    public var tokenURL: String
    public var redirectURI: String
    /// Space-separated scope list.
    public var scopes: String

    public init(
        clientId: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        authorizeURL: String = "https://claude.ai/oauth/authorize",
        tokenURL: String = "https://console.anthropic.com/v1/oauth/token",
        redirectURI: String = "https://console.anthropic.com/oauth/code/callback",
        scopes: String = "org:create_api_key user:profile user:inference"
    ) {
        self.clientId = clientId
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public static let `default` = OAuthConfig()
}

/// PKCE helpers (RFC 7636, S256).
public enum PKCE {
    /// 32 random bytes, base64url without padding (43 characters).
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    /// `base64url(SHA256(verifier))`.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Random opaque state parameter.
    public static func makeState() -> String { makeVerifier() }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Tokens returned by the token endpoint.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]
    public var accountEmail: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scopes: [String] = [], accountEmail: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.accountEmail = accountEmail
    }

    /// True when the token expires within `leeway` seconds of `date`.
    public func expires(within leeway: TimeInterval, at date: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(date) < leeway
    }
}

/// Drives the authorization-code + PKCE flow: `begin()` produces the browser URL, the student pastes the code
/// shown by the callback page, `exchange(pastedCode:)` turns it into tokens, and `refresh(_:)` renews them.
public actor OAuthFlow {
    public let config: OAuthConfig
    private let transport: ClaudeTransport
    private let now: @Sendable () -> Date
    private let authorizeURL: URL
    private let tokenURL: URL
    private var pendingVerifier: String?
    private var pendingState: String?

    /// Throws `ThubanError.network` when the configured URLs are malformed.
    public init(
        config: OAuthConfig = .default,
        transport: ClaudeTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let authorize = URL(string: config.authorizeURL), let token = URL(string: config.tokenURL) else {
            throw ThubanError.network("Invalid OAuth endpoint configuration.")
        }
        self.config = config
        self.transport = transport
        self.now = now
        self.authorizeURL = authorize
        self.tokenURL = token
    }

    /// Generates a fresh verifier/state pair and returns the URL to open in the browser.
    public func begin() -> (url: URL, state: String) {
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeState()
        pendingVerifier = verifier
        pendingState = state
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return (components.url ?? authorizeURL, state)
    }

    /// Exchanges the pasted value (`code`, `code#state`, or the full callback URL) for tokens.
    public func exchange(pastedCode: String) async throws -> OAuthTokens {
        let parsed = try Self.parsePastedCode(pastedCode)
        guard let verifier = pendingVerifier, let state = pendingState else {
            throw ThubanError.parse("Start the sign-in first, then paste the code.")
        }
        if let pastedState = parsed.state, pastedState != state {
            throw ThubanError.parse("The pasted code belongs to a different sign-in attempt. Start again.")
        }
        let body: JSONValue = [
            "grant_type": "authorization_code",
            "code": .string(parsed.code),
            "state": .string(state),
            "client_id": .string(config.clientId),
            "redirect_uri": .string(config.redirectURI),
            "code_verifier": .string(verifier),
        ]
        let tokens = try await requestTokens(body, previous: nil)
        pendingVerifier = nil
        pendingState = nil
        return tokens
    }

    /// Renews an access token. Fields the server omits (refresh token, email) are carried over from `tokens`.
    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        let body: JSONValue = [
            "grant_type": "refresh_token",
            "refresh_token": .string(tokens.refreshToken),
            "client_id": .string(config.clientId),
        ]
        return try await requestTokens(body, previous: tokens)
    }

    // MARK: Parsing

    /// Accepts `code`, `code#state`, or a callback URL carrying `?code=…&state=…`.
    public static func parsePastedCode(_ raw: String) throws -> (code: String, state: String?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThubanError.parse("Paste the code shown after signing in.") }
        if trimmed.contains("://"), let components = URLComponents(string: trimmed) {
            let items = components.queryItems ?? []
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                throw ThubanError.parse("That link does not contain a code.")
            }
            return (code, items.first(where: { $0.name == "state" })?.value)
        }
        let pieces = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let code = pieces[0].trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { throw ThubanError.parse("Paste the code shown after signing in.") }
        let state = pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : nil
        return (code, state.flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        struct Account: Decodable {
            var emailAddress: String?
            enum CodingKeys: String, CodingKey { case emailAddress = "email_address" }
        }

        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        var scope: String?
        var account: Account?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope, account
        }
    }

    private func requestTokens(_ body: JSONValue, previous: OAuthTokens?) async throws -> OAuthTokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try body.data()
        let (stream, response) = try await transport.send(request)
        let data = try await stream.collect()
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONValue(data: data))?["error"]?["message"]?.stringValue
                ?? (try? JSONValue(data: data))?["error_description"]?.stringValue
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw ThubanError.api(status: response.statusCode, message: message.isEmpty ? "Token request failed." : message)
        }
        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ThubanError.parse("Unexpected token response.")
        }
        guard let refreshToken = decoded.refreshToken ?? previous?.refreshToken else {
            throw ThubanError.parse("The token response did not include a refresh token.")
        }
        let scopes = decoded.scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(decoded.expiresIn ?? 3600),
            scopes: scopes,
            accountEmail: decoded.account?.emailAddress ?? previous?.accountEmail
        )
    }
}
