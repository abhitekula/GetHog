import Foundation

/// A minimal dynamic JSON value.
///
/// Needed because several PostHog payloads are genuinely heterogeneous —
/// `/query/` rows are positional arrays of mixed types, and rrweb snapshot
/// events carry arbitrary nested `data`.
public enum JSONValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
}

extension JSONValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public extension JSONValue {
    var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b): String(b)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): d
        case .string(let s): Double(s)
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    var intValue: Int? { doubleValue.map(Int.init) }

    var isNull: Bool { self == .null }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}
