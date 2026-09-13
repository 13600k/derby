import Foundation

/// A fully general JSON value. Derby uses this as the escape hatch for
/// provider-specific fields that have no canonical representation, and as the
/// storage type for tool-call arguments / JSON schemas.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            // Encode integral doubles as integers so provider APIs that are strict
            // about types (e.g. max_tokens) receive `64` rather than `64.0`.
            if v == v.rounded() && abs(v) < 9_007_199_254_740_992 { try c.encode(Int(v)) }
            else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: - Conveniences

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        default: return nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    /// Convert from an untyped Foundation object graph (e.g. `JSONSerialization` output).
    public init(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let v as Bool: self = .bool(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else { self = .number(v.doubleValue) }
        case let v as String: self = .string(v)
        case let v as [Any]: self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as Int: self = .number(Double(v))
        case let v as Double: self = .number(v)
        default: self = .null
        }
    }

    /// Convert to a Foundation object graph suitable for `JSONSerialization`.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v == v.rounded() && abs(v) < 9_007_199_254_740_992 ? Int(v) : v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }

    public var compactJSONString: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// The same bytes for the same value, every time.
    ///
    /// A Swift dictionary's order differs from one instance to the next, so
    /// encoding an equal value twice can put its keys in a different order.
    /// Anything a provider renders into a prompt — tool schemas above all — must
    /// reach it byte-identical on every turn: a reordered key changes the prefix,
    /// and nothing after it is served from the provider's prompt cache.
    public func stableJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    public var stableJSONString: String {
        String(data: (try? stableJSONData()) ?? Data("null".utf8), encoding: .utf8) ?? "null"
    }

    public static func parse(_ string: String) -> JSONValue? {
        guard let d = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: d)
    }

    /// Recursively merge `other` into `self`; object keys from `other` win.
    public func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(let a) = self, case .object(let b) = other else { return other }
        var out = a
        for (k, v) in b {
            if let existing = out[k] { out[k] = existing.merging(v) } else { out[k] = v }
        }
        return .object(out)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
