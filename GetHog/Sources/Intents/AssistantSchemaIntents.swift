import AppIntents
import Foundation

// Apple Intelligence assistant schemas, and what actually fits here.
//
// `@AssistantIntent(schema:)` tells Siri's newer model that an intent *is* a
// thing it already understands — not merely a phrase it can match. That only
// helps when the semantics really line up: a schema carries Apple's expectations
// about parameters, side effects and what the user gets back, and an intent
// wearing a schema it does not mean produces worse behaviour than one wearing
// none, because Siri will now confidently invoke it in situations the app never
// meant.
//
// The schemas the iOS 26 SDK ships are grouped into fourteen domains: assistant,
// books, browser, camera, files, journal, mail, photos, presentation, reader,
// spreadsheet, system, visualIntelligence, whiteboard and wordProcessor. Every
// one of them is about a document, a message, a photo, a page or a capture
// device. None of them is about reading a number out of a product-analytics
// warehouse, and none of the entity schemas describes a dashboard, an insight or
// a feature flag.
//
// So of the four existing intents:
//
// - `OpenDashboardIntent` — the "open" schemas are all domain-bound
//   (`.files.openFile`, `.books.openBook`, `.photos.openAsset`, …). There is no
//   generic "open one of this app's objects", and claiming `.files.openFile` for
//   a dashboard would put PostHog dashboards in Siri's file-handling paths.
//   Nothing adopted.
// - `GetMetricValueIntent` — no domain has a "read the current value of a saved
//   metric" schema. Nothing adopted.
// - `SetFeatureFlagIntent` — no domain has a "flip a remote configuration
//   switch" schema, and it is the last intent in this app that should be made
//   easier for a model to guess at: it changes live production behaviour.
//   Nothing adopted.
// - `SearchEventsIntent` — `.system.search` is close, and is deliberately *not*
//   adopted there. That intent answers in place, with a snippet Siri shows
//   without leaving the conversation; `ShowInAppSearchResultsIntent` means
//   "launch the app and show results in it" and forces `openAppWhenRun`.
//   Wearing the schema would silently turn a spoken answer into an app launch.
//
// Which leaves exactly one honest adoption, below. `.system.search` is the only
// domain-free schema in the set, and the app has precisely the surface it
// describes: one field over every screen and every object in the project, which
// is the whole premise of the fifth tab.

/// "Search GetHog for checkout" — the app's own search, from Siri.
///
/// `.system.search` is the one standard schema this app can mean literally.
/// `ProjectSearchView` is a single field over the app's 28 screens and the
/// project's objects, which is exactly what `ShowInAppSearchResultsIntent`
/// promises: the app opens, showing its own results for the term.
///
/// It deliberately does not fetch. The screen it lands on already holds the
/// project index — one request per project, then everything filtered in memory —
/// so answering from Siri costs the organisation-wide rate-limit budget nothing
/// it was not already going to spend.
///
/// Deliberately absent from `GetHogShortcuts`. A schema intent is understood
/// by Siri's model without a phrase list, and the phrases it would need
/// ("search \(.applicationName) for…") are the ones `SearchEventsIntent` already
/// claims — two intents competing for one utterance is how Siri ends up picking
/// the wrong one.
// `@AppIntent(schema:)`, not `@AssistantIntent(schema:)`: the iOS 26 SDK
// deprecated the latter in favour of the former, which carries the same schema
// checking and also supplies the `AppIntent` conformance itself.
@AppIntent(schema: .system.search)
struct ShowGetHogSearchResultsIntent {
    static let title: LocalizedStringResource = "Search GetHog"
    static let description = IntentDescription(
        "Opens GetHog's search over your project's dashboards, insights, flags and screens.",
        categoryName: "Search"
    )

    var criteria: StringSearchCriteria

    init() {
        self.criteria = StringSearchCriteria(term: "")
    }

    init(term: String) {
        self.criteria = StringSearchCriteria(term: term)
    }

    func perform() async throws -> some IntentResult {
        // Same hand-off every other opening intent uses: the intent runs out of
        // process and cannot push a view, so it leaves the destination for the
        // app to take as it comes forward.
        IntentNavigationTarget.request(.search(term: criteria.term))
        return .result()
    }
}
