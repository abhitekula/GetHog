import Foundation
import Testing

@testable import GetHogKit

// A notebook body is a ProseMirror document whose children are typed nodes.
// These authored fixtures cover the supported vocabulary and attribute shapes,
// including unknown-node fallback. Nothing depends on the type list being
// exhaustive: a future type must survive as a named node instead of failing the
// whole document or disappearing from its original position.

@Suite("Notebook document")
struct NotebookDocumentTests {

    private func richDocument() throws -> NotebookDocument {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        return try #require(notebook.document)
    }

    @Test("decodes the ProseMirror tree instead of reducing it to a Bool")
    func decodesTree() throws {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        // `hasRichContent` stays true — the list screen and `isRichContentOnly`
        // still depend on it — but it is now derived from a parsed document
        // rather than from the mere presence of a non-null key.
        #expect(notebook.hasRichContent)
        #expect(notebook.document != nil)
        #expect(notebook.document?.blocks.isEmpty == false)
    }

    @Test("keeps blocks in document order")
    func preservesOrder() throws {
        let blocks = try richDocument().blocks
        guard case .heading(let level, let inlines) = blocks.first else {
            Issue.record("expected a heading first, got \(String(describing: blocks.first))")
            return
        }
        #expect(level == 2)
        #expect(inlines.map(\.text).joined() == "Observatory field log dossier")

        guard case .paragraph(let last) = blocks.last else {
            Issue.record("expected a paragraph last, got \(String(describing: blocks.last))")
            return
        }
        #expect(last.map(\.text).joined() == "The fictional observation continues after the next demo cycle with a fresh sample.")
    }

    @Test("splits a paragraph into runs carrying their own marks")
    func inlineMarks() throws {
        let blocks = try richDocument().blocks
        guard case .paragraph(let runs) = blocks[1] else {
            Issue.record("expected the second block to be a paragraph")
            return
        }
        // Reassembling the runs must give back exactly the paragraph's text: a
        // renderer that drops a run silently loses a word mid-sentence, which is
        // far worse than losing its styling.
        #expect(
            runs.map(\.text).joined()
                == "Orbit Lab opened the telescope path and reviewed the orbit chart. "
                + "Open the orbit report before checking example_orbit_saved. "
                + "Every retained value is synthetic."
        )
        #expect(runs.first(where: { $0.text == "telescope path" })?.isBold == true)
        #expect(runs.first(where: { $0.text == "orbit chart" })?.isItalic == true)
        #expect(runs.first(where: { $0.text == "example_orbit_saved" })?.isCode == true)

        let link = try #require(runs.first(where: { $0.href != nil }))
        #expect(link.text == "the orbit report")
        #expect(link.href == "https://observatory.example.org/insights/orbit-review")
    }

    @Test("flattens nested lists but keeps the depth")
    func lists() throws {
        let blocks = try richDocument().blocks
        let items: [NotebookListItem] = blocks.compactMap {
            if case .listItem(let item) = $0 { return item }
            return nil
        }
        // Three bullets, one nested bullet, three numbered, three tasks.
        #expect(items.count == 10)

        let nested = try #require(items.first(where: { $0.inlines.map(\.text).joined() == "Check compact layouts on tablets" }))
        #expect(nested.depth == 1)
        #expect(nested.marker == .bullet)

        let numbered = items.filter { if case .number = $0.marker { return true } else { return false } }
        #expect(numbered.count == 3)
        #expect(numbered.first?.marker == .number(4))
        #expect(numbered.last?.marker == .number(6))

        #expect(items.contains { $0.marker == .task(done: true) })
        #expect(items.contains { $0.marker == .task(done: false) })
    }

    @Test("reads a code block's language and its text")
    func codeBlock() throws {
        let blocks = try richDocument().blocks
        let codes: [(language: String?, text: String)] = blocks.compactMap {
            if case .code(let language, let text) = $0 { return (language, text) }
            return nil
        }
        let block = try #require(codes.first)
        #expect(block.language == "sql")
        #expect(block.text.hasPrefix("SELECT count()"))
        #expect(block.text.contains("example_orbit_saved"))
    }

    @Test("keeps a blockquote as a quote rather than as a plain paragraph")
    func quote() throws {
        let blocks = try richDocument().blocks
        let quotes: [[NotebookInline]] = blocks.compactMap {
            if case .quote(let runs) = $0 { return runs }
            return nil
        }
        let runs = try #require(quotes.first)
        #expect(runs.map(\.text).joined() == "The synthetic retry path still needs an empty state before launch.")
    }

    @Test("keeps a horizontal rule")
    func rule() throws {
        #expect(try richDocument().blocks.contains { if case .rule = $0 { return true } else { return false } })
    }
}

@Suite("Notebook embedded nodes")
struct NotebookEmbedTests {

    private func embeds() throws -> [NotebookEmbed] {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        return try #require(notebook.document).embeds
    }

    @Test("separates a saved-insight reference from an inline query")
    func queryNodes() throws {
        let queries = try embeds().filter { $0.type == .query }
        #expect(queries.count == 2)

        // `{"kind": "SavedInsightNode", "shortId": …}` is the saved form. Both the
        // OpenAPI document and the console bundle agree: the console's own
        // `ph-query` href is `kind === "SavedInsightNode" ? insightView(shortId)`.
        // The distinction is the whole basis of the load policy — a saved insight
        // can be fetched from `.crud` with its cached result, an inline one
        // cannot be drawn without spending a `/query/`.
        let saved = try #require(queries.first)
        #expect(saved.savedInsightShortID == "exampleOrbitFunnel42")
        #expect(saved.inlineQuerySource == nil)
        #expect(saved.title == "Example orbit funnel")

        let inline = try #require(queries.last)
        #expect(inline.savedInsightShortID == nil)
        #expect(inline.inlineQueryKind == "TrendsQuery")
        #expect(inline.inlineQueryDisplay == "ActionsLineGraph")
        // The runnable node is the `source` beneath the `InsightVizNode` wrapper,
        // exactly as `Insight.rawSource` does it — `/query/` refuses the wrapper.
        #expect(inline.inlineQuerySource?["kind"]?.stringValue == "TrendsQuery")
    }

    @Test("reads the identifiers the other screens need to open the referenced object")
    func references() throws {
        let all = try embeds()

        let recording = try #require(all.first { $0.type == .recording })
        #expect(recording.recordingID == "recording-example-42")
        #expect(recording.recordingStartMs == 84_500)

        // A flag id arrives as a JSON number, a survey id as a UUID string. Both
        // have to come back as a string or the caller needs two code paths for
        // what is one concept.
        #expect(all.first { $0.type == .featureFlag }?.entityID == "710301")
        #expect(all.first { $0.type == .survey }?.entityID == "survey-demo-feedback-2026")

        let person = try #require(all.first { $0.type == .person })
        #expect(person.entityID == "person-example-42")
        #expect(person.distinctID == "visitor-example-42")

        #expect(all.first { $0.type == .hogqlSQL }?.sourceCode == "SELECT event, count() AS total FROM events WHERE event LIKE 'example_%' GROUP BY event ORDER BY total DESC")
        #expect(all.first { $0.type == .image }?.imageSource == "https://observatory.example.org/assets/orbit-report.png")
        #expect(all.first { $0.type == .latex }?.latexFormula == "r = 0.42")
        #expect(all.first { $0.type == .recordingPlaylist }?.title == "Example orbit replays")
        #expect(all.first { $0.type == .zendeskTickets }?.attrs["personId"]?.stringValue == "person-example-42")
    }

    @Test("every node type names itself, and says how far this app can draw it")
    func labels() throws {
        // The three-way split is the point. `.full` means a real chart or player
        // appears; `.summary` means the object is identified and openable but its
        // content is not reproduced; `.nameOnly` means all we can honestly do is
        // say the block is there. None of them is silence.
        #expect(NotebookNodeType.query.label == "Query")
        #expect(NotebookNodeType.query.rendering == .full)
        #expect(NotebookNodeType.recording.label == "Session recording")
        #expect(NotebookNodeType.recording.rendering == .full)
        #expect(NotebookNodeType.featureFlag.label == "Feature flag")
        #expect(NotebookNodeType.featureFlag.rendering == .summary)
        #expect(NotebookNodeType.zendeskTickets.label == "Zendesk tickets")
        #expect(NotebookNodeType.zendeskTickets.rendering == .nameOnly)

        for type in NotebookNodeType.allCases {
            #expect(!type.label.isEmpty, "\(type.rawValue) has no label")
            #expect(type.label.first?.isUppercase == true, "\(type.rawValue) label is not a sentence")
            #expect(!type.glyph.isEmpty, "\(type.rawValue) has no glyph")
        }
    }

    @Test("the type list matches the vocabulary the deployed console registers")
    func vocabulary() {
        // Read off `public console bundle` on 2026-01-13: every string the console
        // uses as a notebook node type. Pinned so that a future addition here is
        // a deliberate edit rather than a silent divergence — the same role
        // `DisplayTypeCoverageTests` plays for insight display types.
        let registered: Set<String> = [
            "ph-backlink", "ph-cohort", "ph-customer-journey", "ph-duck-sql",
            "ph-early-access-feature", "ph-embed", "ph-experiment", "ph-feature-flag",
            "ph-feature-flag-code-example", "ph-group", "ph-group-properties",
            "ph-hogql-sql", "ph-image", "ph-issues", "ph-latex", "ph-llm-trace",
            "ph-map", "ph-person", "ph-person-feed", "ph-person-properties",
            "ph-python", "ph-python-v2", "ph-query", "ph-recording",
            "ph-recording-playlist", "ph-related-groups", "ph-replay-timestamp",
            "ph-sql-v2", "ph-support-tickets", "ph-survey", "ph-task-create",
            "ph-usage-metrics", "ph-zendesk-tickets",
        ]
        #expect(Set(NotebookNodeType.allCases.map(\.rawValue)) == registered)
    }
}

@Suite("Notebook unsupported nodes")
struct NotebookUnsupportedNodeTests {

    private func document() throws -> NotebookDocument {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        return try #require(notebook.document)
    }

    @Test("an unknown node becomes a named block rather than vanishing")
    func unknownNodeSurvives() throws {
        // The failure this exists to prevent is the notebook equivalent of the
        // WorldMap defect: a block the reader cannot see is indistinguishable
        // from a block the author never wrote, and the reader has no way to tell
        // the document is incomplete.
        let unsupported = try document().unsupportedNodes
        #expect(unsupported.count == 2)

        let future = try #require(unsupported.first { $0.rawType == "ph-hypothetical-future-node" })
        // PostHog's own naming convention is `ph-kebab-case`; humanising it gives
        // a reader something better than the raw string, and the raw string is
        // kept alongside so a bug report can name the node exactly.
        #expect(future.label == "Hypothetical future node")

        let mermaid = try #require(unsupported.first { $0.rawType == "mermaid" })
        #expect(mermaid.label == "Mermaid")
    }

    @Test("an unknown node keeps its position in the document")
    func unknownNodeKeepsPosition() throws {
        let blocks = try document().blocks
        let index = try #require(
            blocks.firstIndex { if case .unsupported(let n) = $0 { return n.rawType == "mermaid" } else { return false } }
        )
        // It sits between the ph-hypothetical-future-node block and the closing
        // paragraph: the reader sees the gap where it belongs, not at the end.
        guard case .paragraph(let after) = blocks[index + 1] else {
            Issue.record("expected the closing paragraph after the mermaid node")
            return
        }
        #expect(after.map(\.text).joined() == "The fictional observation continues after the next demo cycle with a fresh sample.")
    }

    @Test("an unknown node offers whatever text it carried")
    func unknownNodeCarriesText() throws {
        let mermaid = try #require(document().unsupportedNodes.first { $0.rawType == "mermaid" })
        // A mermaid block's diagram source is its text content. Showing it is
        // strictly better than an empty card: it is what the author typed.
        #expect(mermaid.text == "graph LR; Draft-->Review; Review-->Publish;")
    }

    @Test("counts unsupported node types once each for a document-level notice")
    func summary() throws {
        #expect(try document().unsupportedTypeNames == ["Hypothetical future node", "Mermaid"])
    }
}

@Suite("Notebook document fallbacks")
struct NotebookFallbackTests {

    @Test("a document this build cannot walk falls back to text rather than to nothing")
    func opaqueDocument() throws {
        // The markdown generation. `/api/schema/` says a markdown notebook's
        // `content` is "a ProseMirror doc wrapping a single markdown node", and
        // its source lives in a `markdown` field that the notebook retrieve
        // endpoint does not return at all — only `/sql_v2/state/` does. With no
        // The fallback is structural and needs no type-string guess: a document that
        // yielded no prose blocks, next to a non-empty `text_content`, is a
        // document in a shape this build cannot walk. The screen shows the text
        // and says so, rather than showing a page of unsupported cards.
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_opaque_content.json")
        )
        let document = try #require(notebook.document)
        #expect(!document.hasProse)
        #expect(document.blocks.count == 2)
        #expect(notebook.readingStrategy == .plainTextFallback)
    }

    @Test("a rich document is read as rich")
    func richDocumentStrategy() throws {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        #expect(try #require(notebook.document).hasProse)
        #expect(notebook.readingStrategy == .richContent)
    }

    @Test("a notebook with neither a tree nor text is reported as empty, not as broken")
    func emptyNotebook() throws {
        let json = #"{"id":"x","short_id":"x","title":"","content":null,"text_content":null}"#
        let notebook = try JSONDecoder().decode(Notebook.self, from: Data(json.utf8))
        #expect(notebook.document == nil)
        #expect(!notebook.hasRichContent)
        #expect(notebook.readingStrategy == .empty)
    }

    @Test("a tree with no text equivalent still renders from the tree")
    func richContentOnly() throws {
        // The pre-existing fixture: a notebook of blocks whose `text_content` is
        // whitespace. It used to reach a dead end saying "nothing to show as
        // text"; now the tree is the content and the text was never needed.
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_blocks_only.json")
        )
        let raw = try #require(
            JSONSerialization.jsonObject(with: Fixture.data("notebook_blocks_only.json"))
                as? [String: Any]
        )
        #expect(raw["text_content"] as? String == "   ")
        #expect(notebook.isRichContentOnly)
        #expect(notebook.readingStrategy == .richContent)
        #expect(try #require(notebook.document).embeds.contains { $0.type == .query })
    }

    @Test("survives a malformed tree without losing the notebook")
    func malformedTree() throws {
        // `content` is documented only as "a ProseMirror JSON document
        // structure"; nothing guarantees the shape this build expects. A tree
        // that is a string, or a doc whose `content` is an object, must degrade
        // to no document — never to a decode failure that takes the title,
        // author and dates down with it.
        for body in [#""just a string""#, #"{"type":"doc","content":{"not":"an array"}}"#, "[]"] {
            let json = #"{"id":"x","short_id":"x","title":"T","content":\#(body),"text_content":"hi"}"#
            let notebook = try JSONDecoder().decode(Notebook.self, from: Data(json.utf8))
            #expect(notebook.title == "T")
            #expect(notebook.document?.hasProse != true)
            #expect(notebook.readingStrategy == .plainTextFallback)
        }
    }

    @Test("a node with no attrs at all does not crash the walk")
    func attrlessNode() throws {
        let json = #"""
        {"id":"x","short_id":"x","title":"T","text_content":"t",
         "content":{"type":"doc","content":[
           {"type":"ph-query"},
           {"type":"paragraph"},
           {"type":"heading","attrs":{},"content":[]}
         ]}}
        """#
        let notebook = try JSONDecoder().decode(Notebook.self, from: Data(json.utf8))
        let document = try #require(notebook.document)
        // An empty paragraph is dropped — it is whitespace, not content — but the
        // attribute-less query node is kept, because a query node with nothing in
        // it is still a block the author put there.
        #expect(document.embeds.count == 1)
        #expect(document.embeds.first?.savedInsightShortID == nil)
        #expect(document.blocks.contains { if case .embed = $0 { return true } else { return false } })
    }
}

@Suite("Notebook insight load policy")
struct NotebookInsightLoadPolicyTests {

    private func embeds() throws -> [NotebookEmbed] {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        return try #require(notebook.document).embeds
    }

    @Test("a saved-insight node is fetchable without spending a query")
    func savedInsightIsCheap() throws {
        let saved = try #require(embeds().first { $0.savedInsightShortID != nil })
        let plan = try #require(NotebookInsightPlan(embed: saved))
        #expect(plan == .fetchSavedInsight(shortID: "exampleOrbitFunnel42"))

        // A saved-insight lookup is classified as CRUD and never forces refresh,
        // so it is safe to plan automatically without spending query budget.
        let endpoint = PostHogAPI.insight(projectID: 1_001, shortID: "exampleOrbitFunnel42")
        #expect(endpoint.category == .crud)
        #expect(endpoint.query.contains(URLQueryItem(name: "short_id", value: "exampleOrbitFunnel42")))
        #expect(!endpoint.query.contains { $0.name == "refresh" })
    }

    @Test("an inline query is deferred to an explicit tap")
    func inlineQueryIsDeferred() throws {
        let inline = try #require(embeds().first { $0.inlineQuerySource != nil })
        let plan = try #require(NotebookInsightPlan(embed: inline))
        guard case .runOnRequest(let source, let kind, let display) = plan else {
            Issue.record("an inline query must never be planned as an automatic fetch")
            return
        }
        #expect(kind == "TrendsQuery")
        #expect(display == "ActionsLineGraph")
        #expect(source["kind"]?.stringValue == "TrendsQuery")

        // The reason this is not automatic: the `.query` budget is 60/minute and
        // it is organisation-wide, shared with the user's production integrations.
        // A twelve-insight notebook firing on appear would spend a fifth of a
        // minute's entire allowance on a scroll the reader did not ask for.
        #expect(RateLimitGovernor.defaultBudgets[.query]?.perMinute == 60)
        #expect(PostHogAPI.runQuery(projectID: 1_001, source: source).category == .query)
    }

    @Test("a node that is not a query has no insight plan at all")
    func nonQueryNodes() throws {
        for embed in try embeds() where embed.type != .query {
            #expect(NotebookInsightPlan(embed: embed) == nil, "\(embed.type.rawValue) planned a query")
        }
    }

    @Test("counts the requests opening a notebook costs")
    func requestBudget() throws {
        let notebook = try JSONDecoder().decode(
            Notebook.self,
            from: Fixture.data("notebook_rich_content.json")
        )
        let document = try #require(notebook.document)
        let cost = document.automaticRequestCost

        // The whole notebook: one `.crud` fetch for the one saved insight, and
        // nothing else. The ten other embeds — an inline query, a replay, a
        // playlist, a flag, a survey, a person, HogQL, an image, LaTeX, Zendesk —
        // cost zero requests until the reader asks.
        #expect(cost.crud == 1)
        #expect(cost.query == 0)
        #expect(cost.analytics == 0)
        #expect(cost.total == 1)
        #expect(document.embeds.count == 11)
    }
}
