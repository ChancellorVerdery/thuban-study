import Foundation

/// A dynamically typed JSON document. Used for tool inputs/schemas and anything else whose shape is decided at
/// runtime. Round-trips losslessly through `Codable` and through Foundation's `JSONSerialization` objects.
public enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Value is not valid JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Foundation bridging

    /// Builds a value from a `JSONSerialization`-style object (`NSNull`, `Bool`, numbers, `String`, `[Any]`,
    /// `[String: Any]`). Returns `nil` for anything that is not representable as JSON.
    public init?(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let v as JSONValue:
            self = v
        case let n as NSNumber:
            if n.isBoolean { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let b as Bool:
            self = .bool(b)
        case let i as Int:
            self = .number(Double(i))
        case let d as Double:
            self = .number(d)
        case let f as Float:
            self = .number(Double(f))
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for element in a {
                guard let v = JSONValue(any: element) else { return nil }
                out.append(v)
            }
            self = .array(out)
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(o.count)
            for (k, element) in o {
                guard let v = JSONValue(any: element) else { return nil }
                out[k] = v
            }
            self = .object(out)
        case Optional<Any>.none:
            self = .null
        default:
            return nil
        }
    }

    /// Parses JSON text.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Parses JSON text.
    public init(jsonString: String) throws {
        try self.init(data: Data(jsonString.utf8))
    }

    /// The `JSONSerialization`-compatible representation (`NSNull` for `.null`).
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d):
            if d == d.rounded(), abs(d) < 9_007_199_254_740_992 { return Int(d) }
            return d
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        }
    }

    /// Serialized JSON bytes.
    public func data(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Serialized JSON text.
    public func jsonString(pretty: Bool = false) -> String {
        (try? data(pretty: pretty)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    // MARK: Accessors

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var doubleValue: Double? { if case .number(let d) = self { return d } else { return nil } }
    public var intValue: Int? {
        guard case .number(let d) = self, d == d.rounded(), abs(d) < 9_007_199_254_740_992 else { return nil }
        return Int(d)
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }

    /// Member of an object, or `nil` when this is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            var o = objectValue ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }

    /// Element of an array, or `nil` when this is not an array or the index is out of range.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString() }
}

private extension NSNumber {
    /// `JSONSerialization` returns booleans as `NSNumber` backed by `CFBoolean`.
    var isBoolean: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
