import Foundation

/// The one error type the app surfaces. Modules wrap their underlying failures into a case here.
public enum ThubanError: Error, LocalizedError, Sendable, Equatable {
    /// No Claude credentials are configured.
    case notConnected
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
             .engine(let message), .store(let message):
            return message
        case .invalidTemplate(let problems):
            return problems.joined(separator: "\n")
        case .notConnected, .cancelled:
            return nil
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
