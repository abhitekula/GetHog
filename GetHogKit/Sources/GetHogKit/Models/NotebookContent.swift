import Foundation

// A notebook body is a ProseMirror document. `GET https://us.posthog.com/api/schema/`
// — the deployed OpenAPI document, not the prose docs — describes `content` as
// "Notebook content as a ProseMirror JSON document structure", and that is the
// whole of the contract: a `doc` node with a `content` array of typed child
// nodes, each with optional `attrs`, optional `content`, and for text nodes a
// `text` string and a `marks` array.
//
// Everything below treats that structure as the *only* guarantee. Project [REMOVED PRIVATE DATA]
// has zero notebooks, so no part of this could be pinned to a captured response
// the way the rest of this directory is; the node vocabulary instead came from
// the deployed console's own JavaScript, which registers each node with its
// exact attribute map. That is good evidence for what exists and no evidence at
// all for what does not, which is why the walk below is written so that an
// unrecognised node is a *result*, never a failure.

// MARK: - Node vocabulary

/// A notebook node type PostHog's console registers.
///
/// The raw values are the node-type strings read off the deployed editor bundle
/// (`app-static-prod.posthog.com/static/[REMOVED PRIVATE DATA]`, 2026-07-30).
/// `NotebookContentTests.vocabulary` pins the set, so adding a case here is a
/// deliberate edit rather than a silent divergence — the same role
/// `DisplayTypeCoverageTests` plays for insight display types.
///
/// A type *absent* from this enum is not an error. PostHog ships notebook nodes
/// faster than this app can adopt them, and the whole point of
/// `NotebookUnsupportedNode` is that the unknown ones still reach the reader.
public enum NotebookNodeType: String, Sendable, Hashable, CaseIterable {
    case backlink = "ph-backlink"
    case cohort = "ph-cohort"
    case customerJourney = "ph-customer-journey"
    case duckSQL = "ph-duck-sql"
    case earlyAccessFeature = "ph-early-access-feature"
    case embed = "ph-embed"
    case experiment = "ph-experiment"
    case featureFlag = "ph-feature-flag"
    case featureFlagCodeExample = "ph-feature-flag-code-example"
    case group = "ph-group"
    case groupProperties = "ph-group-properties"
    case hogqlSQL = "ph-hogql-sql"
    case image = "ph-image"
    case issues = "ph-issues"
    case latex = "ph-latex"
    case llmTrace = "ph-llm-trace"
    case map = "ph-map"
    case person = "ph-person"
    case personFeed = "ph-person-feed"
    case personProperties = "ph-person-properties"
    case python = "ph-python"
    case pythonV2 = "ph-python-v2"
    case query = "ph-query"
    case recording = "ph-recording"
    case recordingPlaylist = "ph-recording-playlist"
    case relatedGroups = "ph-related-groups"
    case replayTimestamp = "ph-replay-timestamp"
    case sqlV2 = "ph-sql-v2"
    case supportTickets = "ph-support-tickets"
    case survey = "ph-survey"
    case taskCreate = "ph-task-create"
    case usageMetrics = "ph-usage-metrics"
    case zendeskTickets = "ph-zendesk-tickets"

    /// PostHog's own name for the node, singularised.
    ///
    /// Taken verbatim from the console's notebook filter menu ("Containing:
    /// Queries, Session recordings, …") in the same bundle, then put in the
    /// singular because these label one block rather than a category. Using
    /// PostHog's words matters: a reader who goes looking for the block in the
    /// web console should find it called the same thing.
    public var label: String {
        switch self {
        case .backlink: "Link to a PostHog object"
        case .cohort: "Cohort"
        case .customerJourney: "Customer journey"
        case .duckSQL: "SQL (DuckDB)"
        case .earlyAccessFeature: "Early access feature"
        case .embed: "Embedded page"
        case .experiment: "Experiment"
        case .featureFlag: "Feature flag"
        case .featureFlagCodeExample: "Feature flag code example"
        case .group: "Group"
        case .groupProperties: "Group properties"
        case .hogqlSQL: "SQL (HogQL)"
        case .image: "Image"
        case .issues: "Issues"
        case .latex: "Formula"
        case .llmTrace: "LLM traces"
        case .map: "Map"
        case .person: "Person"
        case .personFeed: "Session feed"
        case .personProperties: "Person properties"
        case .python: "Python"
        case .pythonV2: "Python (v2)"
        case .query: "Query"
        case .recording: "Session recording"
        case .recordingPlaylist: "Session replay playlist"
        case .relatedGroups: "Related groups"
        case .replayTimestamp: "Session recording comment"
        case .sqlV2: "SQL (v2)"
        case .supportTickets: "Support tickets"
        case .survey: "Survey"
        case .taskCreate: "Suggested task"
        case .usageMetrics: "Usage metrics"
        case .zendeskTickets: "Zendesk tickets"
        }
    }

    /// SF Symbol for the block, matching the glyph the equivalent screen uses
    /// elsewhere in the app so a notebook block and its destination look related.
    public var glyph: String {
        switch self {
        case .backlink: "link"
        case .cohort: "person.3"
        case .customerJourney: "point.topleft.down.curvedto.point.bottomright.up"
        case .duckSQL, .hogqlSQL, .sqlV2: "tablecells"
        case .earlyAccessFeature: "sparkles"
        case .embed: "globe"
        case .experiment: "flask"
        case .featureFlag, .featureFlagCodeExample: "flag"
        case .group, .groupProperties, .relatedGroups: "building.2"
        case .image: "photo"
        case .issues: "exclamationmark.triangle"
        case .latex: "function"
        case .llmTrace: "brain"
        case .map: "map"
        case .person, .personProperties: "person"
        case .personFeed: "list.bullet.rectangle"
        case .python, .pythonV2: "chevron.left.forwardslash.chevron.right"
        case .query: "chart.xyaxis.line"
        case .recording: "play.rectangle"
        case .recordingPlaylist: "rectangle.stack.badge.play"
        case .replayTimestamp: "text.bubble"
        case .supportTickets, .zendeskTickets: "lifepreserver"
        case .survey: "list.clipboard"
        case .taskCreate: "checklist"
        case .usageMetrics: "chart.bar"
        }
    }

    /// How far this app goes in reproducing the block.
    ///
    /// Stated per type rather than discovered at render time, because the reader
    /// is entitled to know *which* kind of incomplete they are looking at. The
    /// three are meaningfully different promises and none of them is silence:
    ///
    /// - `.full` — the block's *authored* content is reproduced: a real chart,
    ///   a real player, the author's own text, code or formula. Not always
    ///   everything the console puts in the block — a SQL or Python node's last
    ///   *run output* is cached in attributes this build has never seen
    ///   populated, and the view says so where it shows the source.
    /// - `.summary` — the referenced object is identified and openable, but what
    ///   the console draws inside the block is not reproduced here. A flag node
    ///   in the console shows the flag's rollout and its variants; this shows the
    ///   flag, named, and a way into the flag screen.
    /// - `.nameOnly` — the block is named and nothing more. Every one of these
    ///   is a panel with no phone equivalent and no id worth chasing — the
    ///   customer-analytics tabs, the Zendesk and support integrations.
    public var rendering: NotebookNodeRendering {
        switch self {
        case .query, .recording, .image, .latex, .hogqlSQL, .duckSQL, .sqlV2,
             .python, .pythonV2, .taskCreate:
            .full
        case .featureFlag, .featureFlagCodeExample, .survey, .experiment, .cohort,
             .earlyAccessFeature, .person, .personProperties, .group,
             .groupProperties, .recordingPlaylist, .backlink, .embed, .map,
             .replayTimestamp:
            .summary
        case .customerJourney, .issues, .llmTrace, .personFeed, .relatedGroups,
             .supportTickets, .usageMetrics, .zendeskTickets:
            .nameOnly
        }
    }
}

public enum NotebookNodeRendering: Sendable, Hashable {
    case full
    case summary
    case nameOnly
}

// MARK: - Inline text

/// One run of text with a single set of marks.
///
/// ProseMirror stores a styled paragraph as a sequence of text nodes, each
/// carrying its own marks, so a run is the natural unit. Reassembling every run
/// in a block must give back the block's text exactly: dropping a run whose
/// marks are not understood would remove a word from the middle of a sentence,
/// which is much worse than losing its styling.
public struct NotebookInline: Sendable, Hashable {
    public let text: String
    public let isBold: Bool
    public let isItalic: Bool
    public let isCode: Bool
    public let isStrikethrough: Bool
    /// The `href` of a `link` mark, if this run carries one.
    public let href: String?

    public init(
        text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isCode: Bool = false,
        isStrikethrough: Bool = false,
        href: String? = nil
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isCode = isCode
        self.isStrikethrough = isStrikethrough
        self.href = href
    }
}

public extension [NotebookInline] {
    /// The plain text of a run sequence.
    var plainText: String { map(\.text).joined() }
}

// MARK: - Blocks

public struct NotebookListItem: Sendable, Hashable {
    public enum Marker: Sendable, Hashable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    public let marker: Marker
    /// Nesting level, zero for a top-level item.
    ///
    /// Nested lists are flattened into a single sequence carrying their depth
    /// rather than kept as a tree. A phone-width read view indents; it does not
    /// need the tree, and a flat sequence is what a `List` wants.
    public let depth: Int
    public let inlines: [NotebookInline]

    public init(marker: Marker, depth: Int, inlines: [NotebookInline]) {
        self.marker = marker
        self.depth = depth
        self.inlines = inlines
    }
}

/// A node whose type this build does not recognise.
///
/// The reason this type exists at all: a block the reader cannot see is
/// indistinguishable from a block the author never wrote. Dropping it silently
/// turns an incomplete document into a shorter one, and the reader has no way to
/// tell which they are holding. This is the notebook form of the defect
/// `InsightRenderModel.unsupported` was introduced for.
public struct NotebookUnsupportedNode: Sendable, Hashable {
    /// The node's `type` verbatim, so a bug report can name it exactly.
    public let rawType: String
    /// Whatever text the node carried, when it carried any.
    ///
    /// A `mermaid` block's diagram source, a `latex` block's formula: for a node
    /// whose content *is* text, showing the text is strictly better than an
    /// empty card, because it is what the author typed.
    public let text: String?

    public init(rawType: String, text: String? = nil) {
        self.rawType = rawType
        self.text = text
    }

    /// A readable name, derived from the type string.
    ///
    /// PostHog names its nodes `ph-kebab-case`, so dropping the prefix and
    /// sentence-casing the rest turns `ph-hypothetical-future-node` into
    /// "Hypothetical future node". That will not always be the name PostHog
    /// gives the block in its own UI — it cannot be, for a node this build has
    /// never seen — which is why `rawType` is kept beside it rather than thrown
    /// away.
    public var label: String {
        let stem = rawType.hasPrefix("ph-") ? String(rawType.dropFirst(3)) : rawType
        let words = stem
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        // `ph-` on its own, or an empty type string, leaves no words at all and
        // would otherwise title the card with the bare prefix — or with nothing.
        // A card saying nothing is the one outcome this whole type exists to
        // prevent, so it gets words instead; `rawType` is still shown beneath it.
        guard let first = words.first else { return "Unnamed block" }
        // Only the first word is capitalised: these read as sentences on a card,
        // not as Title Case headings.
        let spaced = ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
        return spaced.isEmpty ? "Unnamed block" : spaced
    }
}

/// A node that references a PostHog object.
///
/// Deliberately keeps the raw `attrs` rather than exploding into one case per
/// node type. The attribute maps came from the console bundle and are good, but
/// they are a snapshot of one deploy; a typed case per node would turn every
/// PostHog attribute rename into a silent nil, whereas the accessors below fail
/// visibly at exactly one call site each.
public struct NotebookEmbed: Sendable, Hashable {
    public let type: NotebookNodeType
    /// The author's own title for the block, from the shared `title` attribute.
    public let title: String?
    public let attrs: [String: JSONValue]

    public init(type: NotebookNodeType, title: String?, attrs: [String: JSONValue]) {
        self.type = type
        self.title = title
        self.attrs = attrs
    }

    private var query: JSONValue? { attrs["query"] }

    /// The `short_id` of the saved insight this node embeds, when it embeds one.
    ///
    /// `{"kind": "SavedInsightNode", "shortId": …}` is the saved form. Both live
    /// sources agree: the OpenAPI document defines `SavedInsightNode`, and the
    /// console's own `ph-query` href is
    /// `kind === "SavedInsightNode" ? insightView(shortId) : insightNew({query})`.
    ///
    /// The distinction carries the whole load policy — see `NotebookInsightPlan`.
    public var savedInsightShortID: String? {
        guard let query, query["kind"]?.stringValue == "SavedInsightNode" else { return nil }
        return query["shortId"]?.stringValue
    }

    /// The runnable query node for a node carrying its query inline.
    ///
    /// The `source` beneath the `InsightVizNode` / `DataTableNode` wrapper, for
    /// the same reason `Insight.rawSource` unwraps it: `/query/` refuses the
    /// wrapper. A query that is already a runnable node is returned as-is.
    public var inlineQuerySource: JSONValue? {
        guard let query, savedInsightShortID == nil else { return nil }
        if let source = query["source"], !source.isNull { return source }
        guard let kind = query["kind"]?.stringValue, !kind.isEmpty else { return nil }
        return query
    }

    /// The query kind, e.g. `TrendsQuery` — what `InsightRenderModel` dispatches
    /// on, and never sniffed from the response's shape.
    public var inlineQueryKind: String? { inlineQuerySource?["kind"]?.stringValue }

    /// The stored display type, e.g. `ActionsLineGraph`.
    ///
    /// Needed alongside the kind because a trends response alone cannot say
    /// whether it was meant to be a line, a bar or a single bold number.
    public var inlineQueryDisplay: String? {
        inlineQuerySource?["trendsFilter"]?["display"]?.stringValue
    }

    /// The referenced object's id, as a string.
    ///
    /// A flag id arrives as a JSON number and a survey id as a UUID string;
    /// normalising both to text means a caller needs one path, not two.
    public var entityID: String? {
        guard let value = attrs["id"], !value.isNull else { return nil }
        return value.stringValue
    }

    public var distinctID: String? { attrs["distinctId"]?.stringValue }

    public var recordingID: String? { type == .recording ? entityID : nil }

    /// Where in the recording the block points, in milliseconds.
    public var recordingStartMs: Double? { attrs["timestampMs"]?.doubleValue }

    /// The source of a code node — `ph-hogql-sql`, `ph-duck-sql`, `ph-python`
    /// and the two v2 variants all store it under `code`.
    public var sourceCode: String? {
        guard let code = attrs["code"]?.stringValue, !code.isEmpty else { return nil }
        return code
    }

    /// The language to label a code node with, for the reader's benefit.
    public var sourceLanguage: String? {
        switch type {
        case .hogqlSQL, .sqlV2: "HogQL"
        case .duckSQL: "SQL"
        case .python, .pythonV2: "Python"
        default: nil
        }
    }

    public var imageSource: String? {
        guard let src = attrs["src"]?.stringValue, !src.isEmpty else { return nil }
        return src
    }

    public var latexFormula: String? {
        guard let formula = attrs["formula"]?.stringValue, !formula.isEmpty else { return nil }
        return formula
    }
}

public enum NotebookBlock: Sendable, Hashable {
    case heading(level: Int, inlines: [NotebookInline])
    case paragraph([NotebookInline])
    case listItem(NotebookListItem)
    case quote([NotebookInline])
    case code(language: String?, text: String)
    case rule
    case embed(NotebookEmbed)
    case unsupported(NotebookUnsupportedNode)

    /// Whether this block is prose the reader can actually read.
    ///
    /// Used to tell "a document this build walked successfully" from "a document
    /// whose every block came back unrecognised" — see `Notebook.readingStrategy`.
    var isProse: Bool {
        switch self {
        case .heading, .paragraph, .listItem, .quote, .code: true
        case .rule, .embed, .unsupported: false
        }
    }
}

// MARK: - Document

/// A parsed notebook body.
///
/// Constructed from the raw `content` value and **never throws**. A notebook's
/// title, author and dates are useful on their own; a shape this build did not
/// expect must cost the reader the body, not the whole screen. Every failure
/// path here ends in "fewer blocks", never in an error.
public struct NotebookDocument: Sendable, Hashable {
    public let blocks: [NotebookBlock]

    /// Fails only when the value is not a document at all — absent, null, or not
    /// an object with a `content` array. An *empty* document is a document.
    public init?(_ value: JSONValue?) {
        guard let value, case .object = value else { return nil }
        guard case .array(let children)? = value["content"] else { return nil }
        blocks = Self.walk(children, depth: 0)
    }

    init(blocks: [NotebookBlock]) { self.blocks = blocks }

    public var isEmpty: Bool { blocks.isEmpty }

    /// Whether the walk produced anything readable.
    ///
    /// An embed counts: a notebook of nothing but charts is a notebook this app
    /// can show. What does *not* count is a document whose every block came back
    /// unsupported, which is the signature of a body in a shape this build
    /// cannot walk at all.
    public var hasProse: Bool {
        blocks.contains { $0.isProse } || !embeds.isEmpty
    }

    public var embeds: [NotebookEmbed] {
        blocks.compactMap { if case .embed(let e) = $0 { return e } else { return nil } }
    }

    public var unsupportedNodes: [NotebookUnsupportedNode] {
        blocks.compactMap { if case .unsupported(let n) = $0 { return n } else { return nil } }
    }

    /// Each unrecognised type named once, in the order it first appears, for a
    /// single document-level notice instead of a repeated one per block.
    public var unsupportedTypeNames: [String] {
        var seen = Set<String>()
        return unsupportedNodes.compactMap { seen.insert($0.rawType).inserted ? $0.label : nil }
    }

    /// What opening this notebook costs, before the reader touches anything.
    ///
    /// See `NotebookInsightPlan` for why only saved insights are in here.
    public var automaticRequestCost: NotebookRequestCost {
        NotebookRequestCost(
            crud: embeds.filter { $0.savedInsightShortID != nil }.count,
            query: 0,
            analytics: 0
        )
    }

    // MARK: Walk

    private static func walk(_ nodes: [JSONValue], depth: Int) -> [NotebookBlock] {
        nodes.flatMap { block(from: $0, depth: depth) }
    }

    private static func block(from node: JSONValue, depth: Int) -> [NotebookBlock] {
        guard case .object = node, let type = node["type"]?.stringValue else { return [] }
        let attrs = objectAttrs(node["attrs"])
        let children = arrayContent(node["content"])

        switch type {
        case "doc":
            return walk(children, depth: depth)

        case "paragraph":
            let runs = inlines(children)
            return runs.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [.paragraph(runs)]

        case "heading":
            let runs = inlines(children)
            guard !runs.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            // ProseMirror allows 1...6; clamped because the renderer maps the
            // level onto a font and an out-of-range level would index past it.
            let level = min(max(attrs["level"]?.intValue ?? 1, 1), 6)
            return [.heading(level: level, inlines: runs)]

        case "blockquote":
            let runs = children.flatMap { inlines(arrayContent($0["content"])) }
            return runs.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : [.quote(runs)]

        case "codeBlock", "code_block":
            let text = plainText(children)
            let language = attrs["language"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return text.isEmpty ? [] : [.code(language: language, text: text)]

        case "horizontalRule", "horizontal_rule":
            return [.rule]

        case "bulletList", "bullet_list", "taskList", "task_list":
            return children.flatMap { listItem(from: $0, marker: nil, depth: depth) }

        case "orderedList", "ordered_list":
            let start = attrs["start"]?.intValue ?? 1
            return children.enumerated().flatMap { index, child in
                listItem(from: child, marker: .number(start + index), depth: depth)
            }

        // A text node reaching block level happens in hand-assembled documents;
        // treating it as a paragraph is better than dropping the words.
        case "text":
            let runs = inlines([node])
            return runs.plainText.isEmpty ? [] : [.paragraph(runs)]

        default:
            if let known = NotebookNodeType(rawValue: type) {
                return [.embed(NotebookEmbed(
                    type: known,
                    title: attrs["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    attrs: attrs
                ))]
            }
            let carried = plainText(children)
            return [.unsupported(NotebookUnsupportedNode(
                rawType: type,
                text: carried.isEmpty ? nil : carried
            ))]
        }
    }

    /// A `listItem` or `taskItem`, flattened.
    ///
    /// The item's own text is its inline content; any nested list inside it is
    /// walked at `depth + 1` and emitted after it, and any other block child
    /// (a code block inside a bullet, say) is emitted at the same depth rather
    /// than discarded.
    private static func listItem(
        from node: JSONValue,
        marker: NotebookListItem.Marker?,
        depth: Int
    ) -> [NotebookBlock] {
        guard case .object = node else { return [] }
        let type = node["type"]?.stringValue ?? ""
        let attrs = objectAttrs(node["attrs"])
        let children = arrayContent(node["content"])

        let resolved: NotebookListItem.Marker = if let marker {
            marker
        } else if type == "taskItem" || type == "task_item" {
            .task(done: attrs["checked"] == .bool(true))
        } else {
            .bullet
        }

        var ownRuns: [NotebookInline] = []
        var trailing: [NotebookBlock] = []
        for child in children {
            let childType = child["type"]?.stringValue ?? ""
            switch childType {
            case "paragraph" where trailing.isEmpty:
                ownRuns += inlines(arrayContent(child["content"]))
            case "bulletList", "bullet_list", "orderedList", "ordered_list",
                 "taskList", "task_list":
                trailing += block(from: child, depth: depth + 1)
            default:
                trailing += block(from: child, depth: depth)
            }
        }

        let head: [NotebookBlock] = ownRuns.plainText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : [.listItem(NotebookListItem(marker: resolved, depth: depth, inlines: ownRuns))]
        return head + trailing
    }

    // MARK: Inlines

    private static func inlines(_ nodes: [JSONValue]) -> [NotebookInline] {
        nodes.flatMap { node -> [NotebookInline] in
            guard case .object = node else { return [] }
            switch node["type"]?.stringValue {
            case "text":
                guard let text = node["text"]?.stringValue, !text.isEmpty else { return [] }
                var bold = false, italic = false, code = false, strike = false
                var href: String?
                if case .array(let marks)? = node["marks"] {
                    for mark in marks {
                        switch mark["type"]?.stringValue {
                        case "bold", "strong": bold = true
                        case "italic", "em": italic = true
                        case "code": code = true
                        case "strike", "strikethrough": strike = true
                        case "link": href = mark["attrs"]?["href"]?.stringValue
                        default: break
                        }
                    }
                }
                return [NotebookInline(
                    text: text, isBold: bold, isItalic: italic,
                    isCode: code, isStrikethrough: strike, href: href
                )]
            case "hardBreak", "hard_break":
                return [NotebookInline(text: "\n")]
            default:
                // An inline node of an unknown type still has its text taken, so
                // a mention or an emoji does not silently remove a word.
                let nested = inlines(arrayContent(node["content"]))
                return nested.isEmpty ? [] : nested
            }
        }
    }

    private static func plainText(_ nodes: [JSONValue]) -> String {
        inlines(nodes).plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func objectAttrs(_ value: JSONValue?) -> [String: JSONValue] {
        if case .object(let dict)? = value { return dict }
        return [:]
    }

    private static func arrayContent(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items)? = value { return items }
        return []
    }
}

/// A per-category count of the requests a screen makes on its own.
public struct NotebookRequestCost: Sendable, Hashable {
    public let crud: Int
    public let query: Int
    public let analytics: Int

    public init(crud: Int, query: Int, analytics: Int) {
        self.crud = crud
        self.query = query
        self.analytics = analytics
    }

    public var total: Int { crud + query + analytics }
}

// MARK: - Load policy

/// How an embedded insight gets its numbers, and when.
///
/// This is the rate-limit decision, made in the model so it cannot be quietly
/// undone in a view. PostHog's limits are organisation-wide and shared with
/// whatever else the user has integrated, so a notebook with twelve embedded
/// insights firing twelve `/query/` requests the moment it opens would spend a
/// fifth of a minute's entire `.query` allowance (60/min) on a screen the reader
/// merely scrolled past — and it would do it against their production budget.
///
/// The two cases are not a preference, they are what the API makes possible:
///
/// - **A saved insight can be read without computing anything.** Measured
///   against project [REMOVED PRIVATE DATA] on 2026-07-30: `GET /insights/?short_id=…&limit=1`
///   — the `.crud` builder this app already has — returned in 0.15–0.28s for
///   three insights whose results were cold, each still `result: null`,
///   `is_cached: false`, with no `query_status`; a warm one returned its
///   populated `result`. The request never triggers a computation, so it is safe
///   on appear: it yields either a real chart from the server's existing cache
///   or the honest news that there is not one, and offers to run it.
///
/// - **An inline query has no cache anywhere.** Nothing has ever computed it
///   under that identity, so drawing it *requires* a `POST /query/`. That is
///   deferred to an explicit tap, one block at a time — the same rule
///   `DashboardDetailStore` follows for re-running a dashboard over a new range,
///   and `SavedInsightStore` for escalating to `computeInsight`.
public enum NotebookInsightPlan: Sendable, Hashable {
    /// Fetch the saved insight and draw whatever result the server already has.
    /// `.crud`, never computes.
    case fetchSavedInsight(shortID: String)
    /// Run the query — but only when the reader asks. `.query`.
    case runOnRequest(source: JSONValue, kind: String, display: String?)

    /// `nil` for any node that is not a query node: nothing else in a notebook
    /// can cost a request without the reader asking for it.
    public init?(embed: NotebookEmbed) {
        guard embed.type == .query else { return nil }
        if let shortID = embed.savedInsightShortID {
            self = .fetchSavedInsight(shortID: shortID)
        } else if let source = embed.inlineQuerySource, let kind = embed.inlineQueryKind {
            self = .runOnRequest(source: source, kind: kind, display: embed.inlineQueryDisplay)
        } else {
            // A query node with no usable query. It still renders — as a named
            // block saying so — but there is nothing to fetch.
            return nil
        }
    }
}

// MARK: - Reading strategy

public extension Notebook {
    /// How the detail screen should read this notebook.
    ///
    /// The `.plainTextFallback` case is the honest answer to a real gap. The
    /// deployed OpenAPI document says notebooks now come in two generations: the
    /// legacy rich-text one whose `content` is a full node tree, and a markdown
    /// one whose `content` is "a ProseMirror doc wrapping a single markdown
    /// node" with the source in a `markdown` field that
    /// `GET /notebooks/{short_id}/` does not return at all — only
    /// `/notebooks/{short_id}/sql_v2/state/` does.
    ///
    /// This build does not parse that generation, and the reason is specific:
    /// project [REMOVED PRIVATE DATA] has no notebooks, so the wrapper node's type string could
    /// not be read off any live response, and writing a parser against a guessed
    /// node name is exactly the kind of unverified claim this codebase treats as
    /// a bug. What it does instead needs no guess and no name — a document that
    /// yielded nothing readable, beside a non-empty `text_content`, is a body in
    /// a shape this build cannot walk. The screen shows the text PostHog already
    /// serialised and says that is what it is doing.
    enum ReadingStrategy: Sendable, Hashable {
        case richContent
        case plainTextFallback
        case empty
    }

    var readingStrategy: ReadingStrategy {
        if document?.hasProse == true { return .richContent }
        if textContent != nil { return .plainTextFallback }
        return .empty
    }
}
