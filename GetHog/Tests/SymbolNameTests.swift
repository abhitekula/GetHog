import GetHogKit
import Testing
import UIKit

@testable import GetHog

/// Every SF Symbol the app names actually exists.
///
/// A symbol name is a `String` handed to `Image(systemName:)`, and nothing
/// between the keyboard and the screen checks it: the compiler accepts any
/// string, `Image` returns a view either way, and the failure renders as *blank
/// space*. Three names in this app were invented and shipped —
/// `arrow.down.circle.badge.exclamationmark` (the Ingestion tab and the Health
/// screen's ingestion row), `film.slash` (the "No replay stored" notice) and
/// `bolt.magnifyingglass` (a Shortcuts tile) — and the first was on screen as an
/// empty grey tile beside four rows that all had a glyph. Two of the three were
/// only reachable in states nobody had screenshotted, which is exactly the case
/// a review sweep cannot cover.
///
/// `UIImage(systemName:)` is the check. It resolves against the same catalogue
/// `Image` draws from, on the same OS the app is running on, so it also catches
/// a name that is real but newer than the deployment target.
///
/// The tests below cover the runtime-computed symbol names that cannot be found
/// by a source scan:
///
/// - `AppTab.allCases` covers the tab and section glyphs, which the scan cannot
///   see: they are bare literals in a `switch`, with nothing on the line to say
///   what they are. This is where the ingestion bug lived.
/// - `HealthRoot.glyph` is the other such `switch`, and it held the same dead
///   name.
///
/// `SourceSymbolNameTests` in GetHogKit's host-only test suite separately scans
/// every labelled literal under `GetHog/Sources`. Repository I/O must not run
/// in an iOS Simulator process: opening a compile-time host path there can
/// block indefinitely in the simulator's file-coordination layer.
///
/// `RenderPlaybackTests` and `SessionSummaryScreenTests` already made this check
/// for their own screens, against hand-written lists of names. Those lists are
/// why the idea did not catch these three: a list only covers what somebody
/// remembered to add to it, and no list mentioned the Ingestion tab. They are
/// left alone — they assert things about those screens that this suite does
/// not — but nothing new needs to copy them.
@Suite("Symbol names")
struct SymbolNameTests {

    @Test("Every tab and section glyph resolves", arguments: AppTab.allCases)
    func tabGlyphResolves(_ tab: AppTab) {
        #expect(
            UIImage(systemName: tab.systemImage) != nil,
            "\(tab.rawValue) names \"\(tab.systemImage)\", which is not an SF Symbol"
        )
    }

    /// `HealthIssueKind` is not `CaseIterable` — it lives in GetHogKit and is
    /// deliberately open-ended, because PostHog adds kinds without notice. The
    /// list is therefore written out, and a kind added later will force a new
    /// arm in `HealthRoot.glyph` that this test would not reach. Adding it here
    /// too is the price of the kit staying open-ended.
    @Test(
        "Every health-issue glyph resolves",
        arguments: [
            HealthIssueKind.sdkOutdated,
            .ingestionWarning,
            .webVitals,
            .authorizedURLs,
            .unknown,
        ]
    )
    func healthGlyphResolves(_ kind: HealthIssueKind) {
        let name = HealthRoot.glyph(kind)
        #expect(
            UIImage(systemName: name) != nil,
            "\(kind.rawValue) names \"\(name)\", which is not an SF Symbol"
        )
    }
}
