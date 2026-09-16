import Foundation

/// Shared behaviour for the app's string-backed identifiers. Every ID is a distinct struct wrapping a UUID string so
/// that a `QuestionID` can never be passed where a `ClassID` is expected. Encoded as a bare JSON string.
public protocol ThubanIdentifier: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    var raw: String { get }
    init(raw: String)
}

public extension ThubanIdentifier {
    /// A fresh identifier backed by a new UUID string.
    static func new() -> Self { Self(raw: UUID().uuidString) }

    var description: String { raw }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw < rhs.raw }
}

public struct ClassID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct DocumentID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct QuestionID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct FigureID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct AttemptID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct MessageID: ThubanIdentifier {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}
