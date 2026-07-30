import Foundation
import Observation
import GetHogKit

// What the search field offers before a query exists, and what it remembers
// afterwards.
//
// Everything here is deliberately pure or trivially observable, for the same
// reason the rest of `ProjectSearch.swift` is: a suggestion list that offers the
// wrong thing, offers a duplicate, or grows without bound is a defect no
// screenshot shows.

// MARK: - Recent searches

/// The terms the user has actually submitted on the search field.
///
/// The app had no record of this at all: the project index answers a query in
/// memory, so a search costs nothing to repeat — and consequently nothing ever
/// wrote down that it happened. `.searchSuggestions` is the surface that makes
/// the record worth keeping, because it is the only place a term can be offered
/// back before anything is typed.
///
/// Terms only. Deliberately not "recent results": what a user remembers is the
/// word they typed, and PostHog already keeps the far better record of which
/// *objects* were opened — `last_viewed_at`, which the screen below already
/// reads and which is correct across devices where a local list would not be.
enum RecentSearches {

    /// Six. The suggestion list shares a phone screen with the objects half, and
    /// a history long enough to scroll is a history nobody reads.
    static let limit = 6

    /// Most recent first, case-insensitively de-duplicated, capped.
    ///
    /// De-duplication is by folded case rather than exact string: someone who
    /// searches `Onboarding` and then `onboarding` has searched for one thing
    /// twice, and two rows differing by a capital letter read as a bug. The
    /// newly typed spelling wins, because it is the one they will type again.
    static func adding(_ term: String, to existing: [String], limit: Int = limit) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return existing }
        let kept = existing.filter { $0.localizedCaseInsensitiveCompare(trimmed) != .orderedSame }
        return Array(([trimmed] + kept).prefix(limit))
    }
}

/// `RecentSearches`, persisted.
///
/// `UserDefaults` rather than the App Group: this is one person's typing on one
/// device, it is worth nothing to a widget or an intent, and the App Group is
/// the cross-process contract for things that are — the selected project, the
/// quick-toggle opt-ins.
@MainActor
@Observable
final class RecentSearchStore {

    /// The defaults key. Named for the screen, since nothing else writes it.
    static let defaultsKey = "projectSearch.recentTerms"

    private(set) var terms: [String] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func record(_ term: String) {
        let updated = RecentSearches.adding(term, to: terms)
        guard updated != terms else { return }
        terms = updated
        defaults.set(updated, forKey: Self.defaultsKey)
    }

    func clear() {
        terms = []
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

// MARK: - Suggestions

/// What the field offers, split the way the screen draws it.
struct ProjectSearchSuggestions: Equatable {
    let recentTerms: [String]
    /// Objects by PostHog's own record of when they were last opened — the same
    /// source the screen's default state uses, so the two can never disagree.
    let recentObjects: [FileSystemEntry]

    var isEmpty: Bool { recentTerms.isEmpty && recentObjects.isEmpty }

    /// Five objects, against the fifteen the list below shows.
    ///
    /// The suggestion list is drawn *over* the screen while the field is
    /// focused, so it is competing with the keyboard for the same half-screen. A
    /// suggestion the user has to scroll to has lost to the list underneath it,
    /// which is one tap away and shows all fifteen.
    static let objectLimit = 5

    /// The suggestions for a given moment.
    ///
    /// **Offered only while the query is empty, and that is the load-bearing
    /// rule here.** On iOS the suggestion list replaces the screen's own content
    /// while it is non-empty, so suggestions that survived into a typed query
    /// would hide the live results this field has always shown — the one
    /// behaviour that must not regress. Returning nothing the moment a character
    /// is typed means the field behaves exactly as it did before for every
    /// keystroke after the first.
    ///
    /// It also means a user with no history and a project nobody has opened sees
    /// no suggestion surface at all, rather than an empty panel over their list.
    static func forQuery(
        _ query: String,
        recentTerms: [String],
        entries: [FileSystemEntry],
        objectLimit: Int = objectLimit
    ) -> ProjectSearchSuggestions {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ProjectSearchSuggestions(recentTerms: [], recentObjects: [])
        }
        return ProjectSearchSuggestions(
            recentTerms: recentTerms,
            recentObjects: ProjectSearchIndex.recentlyViewed(in: entries, limit: objectLimit)
        )
    }
}
