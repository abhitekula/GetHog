import Foundation
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
/// The three tests below cover the app's symbol names by three different
/// routes because there is no single place they all live:
///
/// - `sourceLiterals` reads the app's own source and pulls out every string
///   passed to a symbol-taking parameter. No false positives — each match is
///   syntactically a symbol argument — and no drift, because it re-reads the
///   tree every run.
/// - `AppTab.allCases` covers the tab and section glyphs, which the scan cannot
///   see: they are bare literals in a `switch`, with nothing on the line to say
///   what they are. This is where the ingestion bug lived.
/// - `HealthRoot.glyph` is the other such `switch`, and it held the same dead
///   name.
///
/// What none of them covers is a *fourth* switch someone writes next month
/// mapping some new enum to glyph literals. That is why the scan exists: the
/// cheapest way to stay covered is to pass the name through a labelled
/// parameter rather than returning it from a bare `case` arm.
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

    @Test("Every symbol name written in the app's source resolves")
    func sourceLiteralsResolve() throws {
        let names = try Self.sourceLiterals()

        // A scan that finds nothing passes vacuously, which would be worse than
        // no test at all: it would read as coverage while checking nothing. The
        // app names well over a hundred symbols, so any small number here means
        // the scan broke, not that the app got tidier.
        #expect(names.count > 100, "only \(names.count) symbol literals found — the scan is broken")

        for (name, origin) in names.sorted(by: { $0.key < $1.key }) {
            #expect(UIImage(systemName: name) != nil, "\(origin) names \"\(name)\"")
        }
    }

    // MARK: - Scanning

    /// Symbol names written as a labelled argument anywhere under `Sources`,
    /// keyed by name, valued by where one of them was found.
    ///
    /// The labels below are the complete set of ways this app names a symbol in
    /// an argument position: SwiftUI's own two, App Intents' `systemImageName`,
    /// and the three the app's own components declare (`DataRow(glyph:)`,
    /// `RowGlyph(systemName:)`, `ReplayPlayerView.notice(icon:)`). A literal
    /// reached through any of these is unambiguously a symbol name, which is
    /// what keeps this scan free of the false positives a bare "looks dotted"
    /// heuristic would produce — `app.gethog.widget.health` and
    /// `chart.line.uptrend.xyaxis` are the same shape.
    private static func sourceLiterals() throws -> [String: String] {
        let pattern = try NSRegularExpression(
            pattern: #"\b(?:systemName|systemImage|systemImageName|glyph|icon)\s*:\s*"([^"\\]+)""#
        )

        var found: [String: String] = [:]
        for url in try sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let captured = Range(match.range(at: 1), in: text) else { continue }
                let line = text[text.startIndex..<captured.lowerBound]
                    .reduce(into: 1) { count, character in
                        if character == "\n" { count += 1 }
                    }
                found[String(text[captured])] = "\(url.lastPathComponent):\(line)"
            }
        }
        return found
    }

    /// The app's Swift sources, located from this file rather than from the
    /// bundle: the sources are not in the test bundle, and the built app has
    /// only compiled code. `#filePath` is the absolute path of *this* file at
    /// compile time, so the tree is two levels up whatever the checkout is
    /// called.
    private static func sourceFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)  // .../GetHog/Tests/SymbolNameTests.swift
            .deletingLastPathComponent()  // .../GetHog/Tests
            .deletingLastPathComponent()  // .../GetHog
            .appending(path: "Sources")

        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "couldn't read \(root.path) — the sources moved, or the test bundle can't reach them"
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
