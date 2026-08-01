import Foundation
import GetHogKit
import Testing

@testable import GetHog

/// What the search field offers before a query exists, and what it remembers.
///
/// Both halves are pure, and both are the kind of thing a screenshot cannot
/// check: a history that grows without bound, a duplicate that differs by one
/// capital letter, or — the one that matters most — a suggestion list that
/// survives into a typed query and hides the live results behind it.
@Suite("Search suggestions")
struct SearchSuggestionTests {

    private func demoIndex() async throws -> [FileSystemEntry] {
        let url = URL(string: "https://us.posthog.com/api/projects/1001/file_system/?limit=300")!
        let (data, _) = try await DemoTransport().send(URLRequest(url: url))
        return try Page<FileSystemEntry>.decode(from: data).results
    }

    // MARK: - Recent searches

    @Test("keeps the most recent first")
    func mostRecentFirst() {
        var terms: [String] = []
        for term in ["alpha", "beta", "gamma"] {
            terms = RecentSearches.adding(term, to: terms)
        }
        #expect(terms == ["gamma", "beta", "alpha"])
    }

    /// Two rows differing only by a capital letter read as a bug, and they are
    /// one search made twice.
    @Test("treats a term retyped in another case as the same search")
    func caseInsensitiveDeduplication() {
        let terms = RecentSearches.adding("Onboarding", to: ["retention", "onboarding", "funnel"])
        #expect(terms == ["Onboarding", "retention", "funnel"])
    }

    @Test("caps the history rather than letting it grow")
    func capped() {
        var terms: [String] = []
        for index in 0..<20 {
            terms = RecentSearches.adding("term \(index)", to: terms)
        }
        #expect(terms.count == RecentSearches.limit)
        #expect(terms.first == "term 19")
    }

    /// The field submits on an empty return press too, and an empty row in the
    /// history is a row that does nothing when tapped.
    @Test("never records an empty or whitespace term")
    func ignoresBlankTerms() {
        #expect(RecentSearches.adding("", to: ["a"]) == ["a"])
        #expect(RecentSearches.adding("   \n ", to: ["a"]) == ["a"])
    }

    @MainActor
    @Test("persists across a fresh store, which is the only reason to write it down")
    func persists() {
        let defaults = UserDefaults(suiteName: "search-suggestion-tests")!
        defaults.removePersistentDomain(forName: "search-suggestion-tests")

        let store = RecentSearchStore(defaults: defaults)
        store.record("checkout funnel")
        #expect(RecentSearchStore(defaults: defaults).terms == ["checkout funnel"])

        store.clear()
        #expect(RecentSearchStore(defaults: defaults).terms.isEmpty)
    }

    // MARK: - Suggestions

    /// **The rule the whole feature rests on.** On iOS the suggestion list
    /// replaces the screen's content while it is non-empty, so suggestions that
    /// survived into a typed query would hide the live results this field has
    /// always shown — and the field's whole premise is that it answers every
    /// keystroke from an index already in memory.
    @Test("offers nothing at all once a character is typed")
    func suggestsNothingWhileTyping() async throws {
        let index = try await demoIndex()
        let typed = ProjectSearchSuggestions.forQuery(
            "onb", recentTerms: ["retention"], entries: index
        )
        #expect(typed.isEmpty)
        #expect(typed.recentTerms.isEmpty)
        #expect(typed.recentObjects.isEmpty)
    }

    /// A query of nothing but spaces is not a query; the results list treats it
    /// that way too, so the suggestions have to agree or the two halves of the
    /// screen would disagree about whether a search is under way.
    @Test("treats a whitespace query as no query")
    func whitespaceIsNoQuery() async throws {
        let index = try await demoIndex()
        let offered = ProjectSearchSuggestions.forQuery(
            "   ", recentTerms: ["retention"], entries: index
        )
        #expect(!offered.isEmpty)
        #expect(offered.recentTerms == ["retention"])
    }

    /// "A blank search screen is a wasted screen": with no query typed the field
    /// offers what the user typed before, and what PostHog records them opening.
    @Test("offers recent searches and the objects PostHog last saw opened")
    func suggestsBeforeAnythingIsTyped() async throws {
        let index = try await demoIndex()
        let offered = ProjectSearchSuggestions.forQuery(
            "", recentTerms: ["retention", "checkout"], entries: index
        )

        #expect(offered.recentTerms == ["retention", "checkout"])
        #expect(!offered.recentObjects.isEmpty)
        // The same source the screen's own default state uses, capped shorter
        // because the suggestion list shares the screen with the keyboard.
        #expect(offered.recentObjects.count <= ProjectSearchSuggestions.objectLimit)
        #expect(offered.recentObjects.allSatisfy { $0.lastViewedAt != nil })
        #expect(offered.recentObjects == ProjectSearchIndex.recentlyViewed(
            in: index, limit: ProjectSearchSuggestions.objectLimit
        ))
        // Never a folder: a folder has no `ref` and no `href`, so completing to
        // its name would offer a row the results list drops.
        #expect(!offered.recentObjects.contains { $0.type == .folder })
    }

    /// A user with no history, on a project nobody has opened, must get no
    /// suggestion surface at all rather than an empty panel over their list.
    @Test("offers nothing when there is nothing to offer")
    func silentWhenEmpty() {
        let offered = ProjectSearchSuggestions.forQuery("", recentTerms: [], entries: [])
        #expect(offered.isEmpty)
    }

    // MARK: - Why there are no search scopes

    /// The authored overlap contract behind the decision on `ProjectSearchView`.
    ///
    /// A `.searchScopes` control would split this field into "screens" and
    /// "objects" and show one at a time. This counts how often that would be a
    /// lie: how many of the app's own screen names are *also* matched by an
    /// object name or folder in the same project, so that a scoped field would
    /// answer the query with half the truth and no sign that it had.
    ///
    /// The number is asserted rather than merely printed, so the screen's
    /// explanation cannot drift away from the deterministic demo contract.
    @Test("a scope would hide real results for a measurable share of queries")
    func scopeWouldHideResults() async throws {
        let index = try await demoIndex()
        let ambiguous = AppTab.secondary.filter { tab in
            !ProjectSearchIndex.results(in: index, query: tab.title).isEmpty
        }

        #expect(AppTab.secondary.count == 30)
        #expect(ambiguous.count == 2)
        #expect(ambiguous.map(\.title).sorted() == ["Groups", "Surveys"])

        // And the other half of the trade, which is what settles it: the screen
        // rows never bury the object rows, so a scope would not be rescuing
        // anything. Both overlapping queries match exactly one screen,
        // so the object results begin one row down — the position a scope bar
        // would itself have occupied.
        for tab in ambiguous {
            let screens = AppTab.secondary.filter {
                $0.title.localizedCaseInsensitiveContains(tab.title)
            }
            #expect(screens.count == 1, "\(tab.title) matched \(screens.count) screens")
        }
    }
}
