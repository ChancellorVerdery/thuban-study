import Foundation
import os

/// What the Settings "Claude account" card shows.
public enum ConnectionStatus: Sendable, Equatable {
    case notConnected
    case apiKey
    case oauth(email: String?, expiresAt: Date)

    public var isConnected: Bool { self != .notConnected }
}

/// Owns the stored credentials. OAuth wins over an API key; OAuth tokens are refreshed (and re-persisted) when
/// they are within `refreshLeeway` of expiry. Concurrent callers share one in-flight refresh.
public actor CredentialStore {
    public static let refreshLeeway: TimeInterval = 5 * 60

    public typealias Refresher = @Sendable (OAuthTokens) async throws -> OAuthTokens

    private let keychain: KeychainStorage
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.thuban.study", category: "CredentialStore")

    private var loaded = false
    private var oauthTokens: OAuthTokens?
    private var apiKey: String?
    private var refreshTask: Task<OAuthTokens, Error>?

    /// - Parameters:
    ///   - keychain: where secrets live; defaults to the macOS Keychain.
    ///   - refresher: renews OAuth tokens; defaults to `OAuthFlow.refresh`.
    ///   - now: injectable clock.
    public init(
        keychain: KeychainStorage = SecurityKeychain(),
        refresher: Refresher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.refresher = refresher ?? { tokens in try await OAuthFlow().refresh(tokens) }
        self.now = now
    }

    // MARK: Contract API

    /// The auth to use right now, refreshing OAuth tokens when they are about to expire.
    public func currentAuth() async throws -> ClaudeAuth {
        try loadIfNeeded()
        if let tokens = oauthTokens {
            let fresh = tokens.expires(within: Self.refreshLeeway, at: now()) ? try await refreshCoalesced(tokens) : tokens
            return .oauth(accessToken: fresh.accessToken)
        }
        if let apiKey, !apiKey.isEmpty { return .apiKey(apiKey) }
        throw ThubanError.notConnected
    }

    public func setAPIKey(_ key: String) throws {
        try loadIfNeeded()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ThubanError.store("The API key is empty.") }
        try keychain.save(Data(trimmed.utf8), account: Keychain.apiKeyAccount)
        apiKey = trimmed
    }

    public func setOAuth(_ tokens: OAuthTokens) throws {
        try loadIfNeeded()
        try persist(tokens)
        oauthTokens = tokens
    }

    public func disconnect() throws {
        try keychain.delete(account: Keychain.oauthAccount)
        try keychain.delete(account: Keychain.apiKeyAccount)
        oauthTokens = nil
        apiKey = nil
        refreshTask?.cancel()
        refreshTask = nil
        loaded = true
    }

    public func status() async -> ConnectionStatus {
        try? loadIfNeeded()
        if let tokens = oauthTokens { return .oauth(email: tokens.accountEmail, expiresAt: tokens.expiresAt) }
        if let apiKey, !apiKey.isEmpty { return .apiKey }
        return .notConnected
    }

    // MARK: Internals

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        if let data = try keychain.load(account: Keychain.oauthAccount) {
            oauthTokens = try? Self.decoder.decode(OAuthTokens.self, from: data)
            if oauthTokens == nil { logger.error("Stored OAuth tokens were unreadable; ignoring them.") }
        }
        if let data = try keychain.load(account: Keychain.apiKeyAccount) {
            apiKey = String(decoding: data, as: UTF8.self)
        }
        loaded = true
    }

    private func persist(_ tokens: OAuthTokens) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(tokens)
        } catch {
            throw ThubanError.store("Could not encode the OAuth tokens.")
        }
        try keychain.save(data, account: Keychain.oauthAccount)
    }

    private func refreshCoalesced(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if let task = refreshTask { return try await task.value }
        let refresher = self.refresher
        let task = Task { try await refresher(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            try persist(fresh)
            oauthTokens = fresh
            return fresh
        } catch {
            // A refresh that fails while the old token is still valid is not fatal.
            if tokens.expiresAt > now() {
                logger.error("Token refresh failed; using the current token until it expires: \(error.localizedDescription, privacy: .public)")
                return tokens
            }
            throw ClaudeClient.normalize(error)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
