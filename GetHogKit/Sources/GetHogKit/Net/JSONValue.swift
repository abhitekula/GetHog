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
        case .number(let d): Self.render(d)
        case .bool(let b): String(b)
        default: nil
        }
    }

    /// Renders a JSON number as text, or `nil` when there is nothing useful to
    /// show.
    ///
    /// `Int(d)` traps on infinity and on any magnitude past `Int.max`, and a
    /// HogQL result reaches both: an aggregate that divided by a count which
    /// turned out to be zero, and plain `1e300`, which JSON permits and
    /// `JSONDecoder` hands back as a `Double`. Either one crashed the app
    /// wherever a query result is drawn as text — the events feed, the SQL
    /// console, warehouse rows. NaN escaped only by accident, because it compares
    /// unequal to its own `rounded()`, so the guard is explicit rather than
    /// leaning on that.
    ///
    /// Non-finite values render as *absent* rather than as "inf": the property is
    /// already Optional, every caller treats `nil` as no value, and an empty cell
    /// says more than the literal text "inf" does.
    ///
    /// The integer form stops at 2^53, where a `Double` no longer holds every
    /// integer and a long digit string would claim an exactness the value does
    /// not have. Same cutoff as `InsightCSV.number`, deliberately — two
    /// thresholds for rendering the same numbers would be a trap for whoever
    /// reads this next.
    private static func render(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == value.rounded(), abs(value) < 9e15 {
            return String(Int(value))
        }
        return String(value)
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
