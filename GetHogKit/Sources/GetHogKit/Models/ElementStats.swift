import Foundation

// `/api/projects/:id/elements/stats/` is the half of a clickmap that names
// things. It answers "what did people click" without needing the page itself,
// which makes it the one part of PostHog's heatmap that translates to a phone
// unchanged.

// MARK: - Click kinds

/// What kind of click a stats row counted.
///
/// The endpoint mixes all three into one list. Ranking them together as "most
/// clicked" would credit a dead click — one that provably did nothing — with the
/// same engagement as a real one, so the kind travels with the count everywhere.
public enum ElementClickKind: String, Sendable, Hashable, Identifiable {
    case autocapture = "$autocapture"
    case rageClick = "$rageclick"
    case deadClick = "$dead_click"
    case other

    public var id: String { rawValue }

    public init(eventType: String?) {
        self = eventType.flatMap { ElementClickKind(rawValue: $0) } ?? .other
    }

    public var title: String {
        switch self {
        case .autocapture: "Clicks"
        case .rageClick: "Rage clicks"
        case .deadClick: "Dead clicks"
        case .other: "Other"
        }
    }

    /// Singular, for a row that describes one element.
    public var noun: String {
        switch self {
        case .autocapture: "clicks"
        case .rageClick: "rage clicks"
        case .deadClick: "dead clicks"
        case .other: "events"
        }
    }

    public var systemImage: String {
        switch self {
        case .autocapture: "hand.tap"
        case .rageClick: "exclamationmark.bubble"
        case .deadClick: "hand.raised.slash"
        case .other: "questionmark.circle"
        }
    }

    /// What the reader should do about seeing one, since the difference between
    /// these three is the whole point of the screen.
    public var explanation: String {
        switch self {
        case .autocapture: "Ordinary clicks captured automatically."
        case .rageClick: "Several clicks in quick succession on one spot — usually something that looks tappable but isn't responding."
        case .deadClick: "A click that changed nothing on the page."
        case .other: "An event type this app doesn't recognise."
        }
    }

    /// The kinds worth offering as a filter, in the order they appear.
    public static let selectable: [ElementClickKind] = [.autocapture, .rageClick, .deadClick]

    /// The values the endpoint's `include` parameter accepts.
    public static let requestableTypes = ["$autocapture", "$rageclick", "$dead_click"]
}

// MARK: - Element chain

/// One node of the DOM ancestor chain autocapture recorded with a click.
public struct ElementNode: Sendable, Decodable, Hashable {
    /// `order: 0` is the element that was actually clicked; higher orders walk
    /// outward toward `<body>`.
    public let order: Int?
    public let tagName: String?
    public let text: String?
    public let href: String?
    public let elementID: String?
    public let classes: [String]
    public let nthChild: Int?
    public let nthOfType: Int?

    /// Raw attribute map. Keys are *usually* `attr__`-prefixed, but this is
    /// scraped from real page markup: a single unquoted attribute on the page is
    /// enough for PostHog to store a whole run of markup as a key. Nothing here
    /// may assume a prefix, a format, or that a value means what it says.
    public let attributes: [String: String]

    enum CodingKeys: String, CodingKey {
        case order, text, href, attributes
        case tagName = "tag_name"
        case elementID = "attr_id"
        case classes = "attr_class"
        case nthChild = "nth_child"
        case nthOfType = "nth_of_type"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent(Int.self, forKey: .order)
        tagName = try c.decodeIfPresent(String.self, forKey: .tagName).flatMap {
            $0.isEmpty ? nil : $0
        }
        text = try c.decodeIfPresent(String.self, forKey: .text)
        href = try c.decodeIfPresent(String.self, forKey: .href).flatMap { $0.isEmpty ? nil : $0 }
        elementID = try c.decodeIfPresent(String.self, forKey: .elementID).flatMap {
            $0.isEmpty ? nil : $0
        }
        // Null for any element without a class attribute, which is most of them.
        classes = (try? c.decodeIfPresent([String].self, forKey: .classes)) ?? []
        // Null on nodes PostHog could not position in their parent.
        nthChild = try c.decodeIfPresent(Int.self, forKey: .nthChild)
        nthOfType = try c.decodeIfPresent(Int.self, forKey: .nthOfType)

        // Decoded loosely and flattened to strings: the values are page-authored
        // and a single non-string would otherwise cost the whole element chain.
        let raw = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .attributes)) ?? [:]
        attributes = raw.compactMapValues(\.stringValue)
    }

    /// Captured text with its newlines and indentation collapsed. Real markup
    /// hands back multi-line, heavily padded strings that would otherwise wreck
    /// a list row's height.
    public var displayText: String? {
        ElementNode.normalized(text)
    }

    public var ariaLabel: String? {
        ElementNode.normalized(attributes["attr__aria-label"])
    }

    /// CSS-ish identity for an element with no words of its own.
    public var selector: String {
        var out = tagName ?? ""
        if let elementID { out += "#\(elementID)" }
        if let first = classes.first, !first.isEmpty { out += ".\(first)" }
        return out
    }

    /// A short human name for this node, if it has one at all.
    public var spokenName: String? { displayText ?? ariaLabel }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

// MARK: - Stats row

/// One element, and how many times it was clicked.
public struct ElementStat: Sendable, Decodable, Hashable {
    public let count: Int
    public let hash: String?
    public let eventType: String?
    public let elements: [ElementNode]

    enum CodingKeys: String, CodingKey {
        case count, hash, elements
        case eventType = "type"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        eventType = try c.decodeIfPresent(String.self, forKey: .eventType)
        elements = (try? c.decodeIfPresent([ElementNode].self, forKey: .elements)) ?? []
    }

    public var kind: ElementClickKind { ElementClickKind(eventType: eventType) }

    /// The element that was clicked — `order: 0`, not the first array entry,
    /// because the array's order is PostHog's business and not a contract.
    public var target: ElementNode? {
        elements.first { $0.order == 0 } ?? elements.min { ($0.order ?? .max) < ($1.order ?? .max) }
    }

    public var tagName: String? { target?.tagName }

    /// The most readable name the clicked element itself offers.
    public var label: String {
        guard let target else { return "Unidentified element" }
        if let text = target.displayText { return text }
        if let aria = target.ariaLabel { return aria }
        if let href = target.href { return href }
        return target.selector.isEmpty ? "Unidentified element" : target.selector
    }

    /// The nearest ancestor that has a name, when the clicked element has none.
    ///
    /// Autocapture records the innermost node under the cursor, which for an
    /// icon button is a bare `<img>`. The label a person would recognise lives
    /// one level out; without it, half a real list reads "img, img, img".
    public var ancestorLabel: String? {
        guard let target, target.displayText == nil, target.ariaLabel == nil else { return nil }
        let targetOrder = target.order ?? 0
        return elements
            .filter { ($0.order ?? .max) > targetOrder }
            .sorted { ($0.order ?? .max) < ($1.order ?? .max) }
            .compactMap(\.spokenName)
            .first
    }

    public var href: String? { target?.href }

    /// Rows ordered by click count, optionally narrowed to one kind.
    ///
    /// Ties keep the order PostHog sent, so a redraw never reshuffles equal rows
    /// under the reader's finger.
    public static func ranked(_ stats: [ElementStat], kind: ElementClickKind?) -> [ElementStat] {
        let filtered = kind.map { wanted in stats.filter { $0.kind == wanted } } ?? stats
        return filtered
            .enumerated()
            .sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }
            .map(\.element)
    }
}
