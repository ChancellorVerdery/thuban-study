import Foundation

/// The one error type the app surfaces. Modules wrap their underlying failures into a case here.
public enum ThubanError: Error, LocalizedError, Sendable, Equatable {
    /// No Claude credentials are configured.
    case notConnected
    /// Stored OAuth tokens were rejected (refresh refused or the API answered 401); the student must sign in again.
    case sessionExpired
    /// The Keychain refused to hand over the stored credentials (the student denied the access prompt or the
    /// keychain is locked).
    case keychainDenied(String)
    case network(String)
    case api(status: Int, message: String)
    case parse(String)
    case unsupportedDocument(String)
    case engine(String)
    case store(String)
    case cancelled
    /// Template validation failed; one entry per problem.
    case invalidTemplate([String])

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your Claude account in Settings to use the tutor and import documents."
        case .sessionExpired:
            return "Your Claude sign-in has expired or was revoked. Reconnect in Settings › Claude account."
        case .keychainDenied(let detail):
            return "Thuban Study was not allowed to read its Keychain items (\(detail)). Click Allow when macOS asks, or reconnect your Claude account in Settings."
        case .network(let detail):
            return "Network error: \(detail)"
        case .api(let status, let message):
            return "Claude API error (\(status)): \(message)"
        case .parse(let detail):
            return "Could not read the response: \(detail)"
        case .unsupportedDocument(let detail):
            return "Unsupported document: \(detail)"
        case .engine(let detail):
            return "Math engine error: \(detail)"
        case .store(let detail):
            return "Storage error: \(detail)"
        case .cancelled:
            return "Cancelled."
        case .invalidTemplate(let problems):
            if problems.isEmpty { return "The question template is invalid." }
            return "The question template is invalid: " + problems.joined(separator: "; ")
        }
    }

    public var failureReason: String? {
        switch self {
        case .api(_, let message), .network(let message), .parse(let message), .unsupportedDocument(let message),
             .engine(let message), .store(let message), .keychainDenied(let message):
            return message
        case .invalidTemplate(let problems):
            return problems.joined(separator: "\n")
        case .notConnected, .sessionExpired, .cancelled:
            return nil
        }
    }

    /// True when the credentials themselves were rejected: an API 401/403 (expired or revoked token, invalid key,
    /// missing permission) or a refresh the token endpoint refused. Retrying cannot help; the student must sign in again.
    public var isAuthFailure: Bool {
        switch self {
        case .api(let status, _): return status == 401 || status == 403
        case .sessionExpired: return true
        default: return false
        }
    }

    /// True when the fix is in Settings › Claude account: no credentials, rejected credentials, or credentials the
    /// Keychain would not hand over.
    public var isCredentialProblem: Bool {
        switch self {
        case .notConnected, .keychainDenied: return true
        default: return isAuthFailure
        }
    }

    /// True for the API's retryable statuses (rate limit, overloaded, server errors).
    public var isRetryable: Bool {
        switch self {
        case .api(let status, _): return status == 429 || status == 529 || (500...599).contains(status)
        case .network: return true
        default: return false
        }
    }
}
