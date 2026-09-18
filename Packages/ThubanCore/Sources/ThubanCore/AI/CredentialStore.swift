import Foundation
import os

/// What the Settings "Claude account" card shows.
public enum ConnectionStatus: Sendable, Equatable {
    case notConnected
    case apiKey
    case oauth(email: String?, expiresAt: Date)
    /// OAuth tokens are stored but were rejected (refresh refused or the API answered 401): sign in again.
    case oauthExpired(email: String?)
    /// The Keychain would not hand over the stored credentials; the detail is user-facing.
    case keychainDenied(String)

    /// Requests can be made right now.
    public var isConnected: Bool {
        switch self {
        case .apiKey, .oauth: return true
        case .notConnected, .oauthExpired, .keychainDenied: return false
        }
    }

    /// Credentials exist but cannot be used until the student acts in Settings.
    public var needsAttention: Bool {
        switch self {
        case .oauthExpired, .keychainDenied: return true
        case .notConnected, .apiKey, .oauth: return false
        }
    }
}

/// Owns the stored credentials. OAuth wins over an API key; OAuth tokens are refreshed (and re-persisted) when
/// they are within `refreshLeeway` of expiry. Concurrent callers share one in-flight refresh and observe the same
/// outcome. Tokens the token endpoint refuses to refresh (or that the API rejects with 401) are marked expired:
/// `status()` then reports `.oauthExpired` and `currentAuth()` throws `ThubanError.sessionExpired` until the
/// student signs in again or disconnects.
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
    /// True once the token endpoint or the API rejected `oauthTokens`; cleared by `setOAuth` / `disconnect`.
    private var oauthRejected = false
    /// The user-facing detail of the last Keychain read the OS refused; nil once a read succeeds.
    private var keychainDenial: String?
    private var refreshTask: Task<OAuthTokens, Error>?
    /// Bumped whenever the stored credentials change so an in-flight refresh knows its result is stale.
    private var generation = 0

    /// - Parameters:
    ///   - keychain: where secrets live; defaults to the app's private credentials file (`FileCredentialStorage`).
    ///   - refresher: renews OAuth tokens; defaults to `OAuthFlow.refresh`.
    ///   - now: injectable clock.
    public init(
        keychain: KeychainStorage = FileCredentialStorage(),
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
            if oauthRejected {
                // Rejected OAuth tokens never fall back to an API key: the account is what the student connected.
                throw ThubanError.sessionExpired
            }
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
        generation += 1
    }

    public func setOAuth(_ tokens: OAuthTokens) throws {
        try loadIfNeeded()
        try persist(tokens)
        oauthTokens = tokens
        oauthRejected = false
        generation += 1
    }

    /// Removes both credentials. Every step runs even when one Keychain delete fails; the first failure is rethrown
    /// after the in-memory state has been cleared, so the store never reports a credential it could not remove.
    public func disconnect() throws {
        var firstFailure: Error?
        for account in [Keychain.oauthAccount, Keychain.apiKeyAccount] {
            do {
                try keychain.delete(account: account)
            } catch {
                logger.error("Keychain delete of \(account, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if firstFailure == nil { firstFailure = error }
            }
        }
        oauthTokens = nil
        apiKey = nil
        oauthRejected = false
        keychainDenial = nil
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        loaded = firstFailure == nil
        if let firstFailure { throw firstFailure }
    }

    /// Forgets the cached credentials so the next call reads storage again (after an external write, e.g. the
    /// one-time move out of the Keychain).
    public func reload() {
        loaded = false
        oauthTokens = nil
        apiKey = nil
        oauthRejected = false
        keychainDenial = nil
        generation += 1
    }

    /// Records that the API rejected the current OAuth token (401/403 on a request): the tokens are marked expired
    /// so `status()` and `currentAuth()` steer the student to sign in again. API keys are left alone.
    public func noteAuthenticationFailure() {
        try? loadIfNeeded()
        guard oauthTokens != nil else { return }
        oauthRejected = true
        logger.error("The API rejected the OAuth token; the student must sign in again.")
    }

    public func status() async -> ConnectionStatus {
        try? loadIfNeeded()
        if let tokens = oauthTokens {
            return oauthRejected
                ? .oauthExpired(email: tokens.accountEmail)
                : .oauth(email: tokens.accountEmail, expiresAt: tokens.expiresAt)
        }
        if let apiKey, !apiKey.isEmpty { return .apiKey }
        if let keychainDenial { return .keychainDenied(keychainDenial) }
        return .notConnected
    }

    // MARK: Internals

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        do {
            if let data = try keychain.load(account: Keychain.oauthAccount) {
                oauthTokens = try? Self.decoder.decode(OAuthTokens.self, from: data)
                if oauthTokens == nil { logger.error("Stored OAuth tokens were unreadable; ignoring them.") }
            }
            if let data = try keychain.load(account: Keychain.apiKeyAccount) {
                apiKey = String(decoding: data, as: UTF8.self)
            }
        } catch ThubanError.keychainDenied(let detail) {
            // Leave `loaded` false so the next call asks the OS again (the student may allow it then).
            keychainDenial = detail
            throw ThubanError.keychainDenied(detail)
        }
        keychainDenial = nil
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

    /// Joins the in-flight refresh or starts one. The whole refresh, including the fallback rules, runs inside the
    /// shared task so every caller sees the same tokens or the same error.
    private func refreshCoalesced(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        if let task = refreshTask { return try await task.value }
        let task = Task { try await self.performRefresh(tokens) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        let startGeneration = generation
        let fresh: OAuthTokens
        do {
            fresh = try await refresher(tokens)
        } catch {
            let failure = ClaudeClient.normalize(error)
            guard generation == startGeneration else { return try currentTokensAfterChange() }
            if Self.refreshWasRefused(failure) {
                oauthRejected = true
                logger.error("The token endpoint refused the refresh; the student must sign in again: \(failure.localizedDescription, privacy: .public)")
                throw ThubanError.sessionExpired
            }
            // A refresh that fails while the old token is still valid is not fatal.
            if tokens.expiresAt > now() {
                logger.error("Token refresh failed; using the current token until it expires: \(failure.localizedDescription, privacy: .public)")
                return tokens
            }
            throw failure
        }
        // Disconnect or a new sign-in while the request was in flight: this result belongs to credentials that
        // no longer exist, so never write it back.
        guard generation == startGeneration else { return try currentTokensAfterChange() }
        oauthTokens = fresh
        // The endpoint has already rotated the refresh token, so keep the new tokens even when the Keychain
        // write fails; they are re-persisted on the next successful save.
        do {
            try persist(fresh)
        } catch {
            logger.error("Could not persist the refreshed tokens; keeping them in memory: \(error.localizedDescription, privacy: .public)")
        }
        return fresh
    }

    private func currentTokensAfterChange() throws -> OAuthTokens {
        guard let current = oauthTokens, !oauthRejected else { throw ThubanError.notConnected }
        return current
    }

    /// A 4xx from the token endpoint (400 invalid_grant, 401, 403) means the refresh token is gone for good.
    private static func refreshWasRefused(_ error: ThubanError) -> Bool {
        if case .api(let status, _) = error { return status == 400 || status == 401 || status == 403 }
        return false
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
