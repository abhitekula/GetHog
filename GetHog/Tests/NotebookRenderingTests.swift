import Foundation
import GetHogKit
import Testing

@testable import GetHog

// The screen-side half of notebook rendering. `NotebookContentTests` in
// GetHogKit pins the document model; these pin the two decisions that live in
// the app: what the reader is told when a block cannot be drawn, and how many
// requests opening a notebook costs.

private func notebook(content: String, text: String? = nil) throws -> Notebook {
    let textField = text.map { "\"\($0)\"" } ?? "null"
    let json = """
    {"id":"n","short_id":"n","title":"T","content":\(content),"text_content":\(textField)}
    """
    return try JSONDecoder().decode(Notebook.self, from: Data(json.utf8))
}

@Suite("Notebook rendering")
struct NotebookRenderingTests {

    @Test("every block a notebook can hold maps to a row this app can build")
    func everyBlockRenders() throws {
        // The invariant: `NotebookBlockRow` switches exhaustively over
        // `NotebookBlock`, and `NotebookEmbedRow` over `NotebookNodeType`. Swift
        // enforces the first two at compile time; what it cannot enforce is that
        // each arm produces something *visible*, which is what the label and
        // glyph checks below stand in for. A node type with no label would draw
        // a card with an empty title — present, but saying nothing.
        for type in NotebookNodeType.allCases {
            let embed = NotebookEmbed(type: type, title: nil, attrs: [:])
            #expect(!embed.type.label.isEmpty)
            #expect(!embed.type.glyph.isEmpty)
            // `NotebookReferenceCard` is the fallback arm, and it must be able to
            // explain any type routed to it — including one added to `.full`
            // later without a bespoke view.
            #expect(NotebookNodeRendering.allRenderings.contains(type.rendering))
        }
    }

    @Test("an unsupported node's card names the node and keeps the raw type")
    func unsupportedCardNamesTheNode() {
        let node = NotebookUnsupportedNode(rawType: "ph-brand-new-widget", text: "some source")
        // The label is what the reader sees; `rawType` is what makes a bug report
        // actionable. Both survive to the view.
        #expect(node.label == "Brand new widget")
        #expect(node.rawType == "ph-brand-new-widget")
        #expect(node.text == "some source")

        // A type with no `ph-` prefix is still named rather than shown raw.
        #expect(NotebookUnsupportedNode(rawType: "mermaid").label == "Mermaid")
        #expect(NotebookUnsupportedNode(rawType: "table").label == "Table")
        // Degenerate input must not produce an empty card title: a card with no
        // words on it is present but says nothing, which is the outcome the
        // unsupported card exists to prevent.
        #expect(NotebookUnsupportedNode(rawType: "ph-").label == "Unnamed block")
        #expect(NotebookUnsupportedNode(rawType: "").label == "Unnamed block")
    }

    @Test("styled text keeps every word, including runs whose marks are unknown")
    func styledTextKeepsEveryWord() {
        let runs = [
            NotebookInline(text: "before "),
            NotebookInline(text: "bold", isBold: true),
            NotebookInline(text: " and "),
            NotebookInline(text: "linked", href: "https://example.com"),
            NotebookInline(text: " after."),
        ]
        // The failure this guards: a renderer that filters runs it cannot style
        // deletes words from the middle of a sentence, and the reader has no way
        // to notice. Reassembly must be lossless.
        #expect(String(runs.styled.characters) == "before bold and linked after.")
        #expect(runs.plainText == "before bold and linked after.")
    }

    @Test("the document footer names what is missing, once")
    func footerNamesMissingTypes() throws {
        let content = """
        {"type":"doc","content":[
          {"type":"paragraph","content":[{"type":"text","text":"Hello"}]},
          {"type":"mermaid"},
          {"type":"mermaid"},
          {"type":"ph-unknown-thing"}
        ]}
        """
        let document = try #require(notebook(content: content).document)
        // Two mermaid blocks, one notice. Repeating the same sentence per block
        // trains the reader to skip it.
        #expect(document.unsupportedTypeNames == ["Mermaid", "Unknown thing"])
        #expect(document.unsupportedNodes.count == 3)
    }

    @Test("opening a notebook of twelve embedded insights costs at most one request per saved insight")
    func requestCostIsBounded() throws {
        // Twelve `ph-query` nodes, all inline queries. This is the case the
        // brief names, and the answer is zero automatic requests: an inline query
        // has no cached result anywhere, so drawing it needs a `POST /query/`,
        // and twelve of those on appear would be a fifth of a minute's entire
        // organisation-wide `.query` allowance spent on a scroll.
        let inline = """
        {"type":"ph-query","attrs":{"query":{"kind":"InsightVizNode","source":{"kind":"TrendsQuery"}}}}
        """
        let content = "{\"type\":\"doc\",\"content\":[\(Array(repeating: inline, count: 12).joined(separator: ","))]}"
        let document = try #require(notebook(content: content).document)
        #expect(document.embeds.count == 12)
        #expect(document.automaticRequestCost.total == 0)

        // Twelve *saved* insights cost twelve `.crud` reads and zero queries —
        // measured: that endpoint returns the server's existing cache and never
        // computes. Twelve is well inside the 360/min crud budget.
        let saved = """
        {"type":"ph-query","attrs":{"query":{"kind":"SavedInsightNode","shortId":"aBcD1234"}}}
        """
        let savedContent = "{\"type\":\"doc\",\"content\":[\(Array(repeating: saved, count: 12).joined(separator: ","))]}"
        let savedDocument = try #require(notebook(content: savedContent).document)
        #expect(savedDocument.automaticRequestCost.crud == 12)
        #expect(savedDocument.automaticRequestCost.query == 0)
        #expect(RateLimitGovernor.defaultBudgets[.crud]?.perMinute ?? 0 >= 12)
    }

    @Test("a body that cannot be walked is shown as text, and said to be text")
    func fallbackIsAnnounced() throws {
        let opaque = try notebook(content: #"{"type":"doc","content":[{"type":"someFutureFormat"}]}"#,
                                  text: "The prose PostHog serialised.")
        #expect(opaque.readingStrategy == .plainTextFallback)

        // And the reverse: a walkable body is never downgraded to text even when
        // `text_content` is present, because the tree carries the charts.
        let rich = try notebook(content: #"{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"hi"}]}]}"#,
                                text: "hi")
        #expect(rich.readingStrategy == .richContent)
    }

    @Test("a response that is not a notebook fails with a sentence, not a Swift dump")
    func decodeFailureIsReadable() {
        // The payload that produced this, historically: demo mode did not route
        // `/notebooks/:shortID/`, so the request fell through to the empty-page
        // catch-all. Both halves of that have since changed — the catch-all is
        // now a 501, and two notebook handles are routed — but the *shape* is
        // what this test is about and it is still one a server can send. It is
        // genuinely not a notebook and must still be an error; what must not
        // happen is the reader being shown `String(describing: DecodingError)`.
        let emptyPage = Data(#"{"count":0,"next":null,"previous":null,"results":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Notebook.self, from: emptyPage)
        }

        do {
            _ = try JSONDecoder().decode(Notebook.self, from: emptyPage)
            Issue.record("expected a decode failure")
        } catch {
            let failure = LoadFailure(PostHogError.decoding(String(describing: error)), loading: "notebook")
            #expect(failure.summary == "PostHog's notebook response wasn't in a shape this app could read.")
            // The dump survives for whoever can use it — behind a disclosure,
            // not as the message.
            #expect(failure.detail?.contains("keyNotFound") == true)
        }
    }

    @Test("a notebook missing one of its two identifiers still decodes")
    func toleratesOneIdentifier() throws {
        // The loosening that came with the fix. Either identifier stands in for
        // the other; only a payload with neither is rejected.
        let shortOnly = try JSONDecoder().decode(
            Notebook.self,
            from: Data(#"{"short_id":"aBcD1234","title":"T"}"#.utf8)
        )
        #expect(shortOnly.id == "aBcD1234")
        #expect(shortOnly.shortID == "aBcD1234")

        let idOnly = try JSONDecoder().decode(
            Notebook.self,
            from: Data(#"{"id":"018f0000-0000-7000-8000-000000000201","title":"T"}"#.utf8)
        )
        #expect(idOnly.shortID == "018f0000-0000-7000-8000-000000000201")
    }
}

private extension NotebookNodeRendering {
    static var allRenderings: [NotebookNodeRendering] { [.full, .summary, .nameOnly] }
}
