import GetHogKit
import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// The rotors, read off the real screens after they have rendered.
///
/// **Why this is not in `GetHogUITests`, where every other rendered-tree
/// assertion in this project lives.** It was written there first, and XCUITest
/// cannot see a rotor. Measured on the Logs screen in demo mode: the whole
/// `XCUIApplication.debugDescription` is 7,661 characters and contains the
/// substring "rotor" zero times, and `XCUIElement.snapshot()`'s dictionary
/// carries exactly thirteen keys — `children, displayID, elementType, enabled,
/// frame, hasFocus, horizontalSizeClass, identifier, label, selected, title,
/// verticalSizeClass, windowContextID`. There is no custom-rotor attribute on
/// the automation bridge at all, so a UI test asserting a rotor could only ever
/// assert something adjacent to it and call that proof. This project has shipped
/// exactly that mistake before — `.accessibilityElement(children: .ignore)` was
/// briefed as the fix for a web-view element leak and changed nothing — so the
/// test moved down a layer rather than being softened.
///
/// One layer down is `UIAccessibilityCustomRotor`, which is what SwiftUI's
/// `accessibilityRotor` actually compiles to, and which is readable in-process
/// once `accessibilityActivate()` has made UIKit build the accessibility tree.
/// Each rotor is then *driven* — `itemSearchBlock` is called repeatedly, exactly
/// as VoiceOver drives it — and what comes back is the sequence of elements the
/// user would be taken to, with the labels they would hear. Nothing here is
/// inferred from the data the rotor was handed; the entries are read out of a
/// rendered tree.
///
/// The screens are the real ones, hosted with the same `DemoTransport` the UI
/// tests drive, so the rows the entries resolve to are the rows the app draws.
/// Serialized because they share `UserDefaults.standard` through `AppModel`'s
/// persisted project id.
@MainActor
@Suite("Accessibility rotors", .serialized)
struct AccessibilityRotorTests {

    // MARK: - Logs

    /// The rows this screen would be measured against if demo mode had a logs
    /// fixture. It does not — `GetHog/Resources/DemoData` carries no logs
    /// fixture at all, so `LogsRoot` renders an empty state there and has no
    /// rotor to read. These are the shapes `LogRow.rows(from:)` produces.
    private static let logLines: [LogRow] = [
        LogRow(id: "l1", timestamp: .now, severity: .info, body: "Handled request", serviceName: "api", traceID: "t1"),
        LogRow(id: "l2", timestamp: .now, severity: .error, body: "Upstream timeout after 30s", serviceName: "api", traceID: "t2"),
        LogRow(id: "l3", timestamp: .now, severity: .debug, body: "Cache warm", serviceName: "worker", traceID: nil),
        LogRow(id: "l4", timestamp: .now, severity: .fatal, body: "Out of memory\nsecond line nobody should hear", serviceName: "worker", traceID: "t4"),
        LogRow(id: "l5", timestamp: .now, severity: .warn, body: "Retrying", serviceName: "api", traceID: nil),
    ]

    @Test("the logs list offers a rotor over the error and fatal lines")
    func logsRotor() async throws {
        let lines = Self.logLines
        let problemIDs = Set(lines.filter(\.severity.isProblem).map(\.id))

        // The screen's own row view, the screen's own list shape and the
        // screen's own rotor declaration — `logsRotor(problems:)` is called by
        // `LogsRoot.list` and by nothing else — with the rows the fixture cannot
        // supply.
        //
        // The `NavigationLink` is load-bearing and was measured to be. Dropped,
        // with everything else identical, this rotor is still *registered* and
        // returns **zero** entries: the id a rotor entry resolves against comes
        // from the row's identified, focusable element, and a bare `DataRow` in
        // a `List` does not provide one. That is exactly the class of defect
        // this file exists to catch — a rotor present in the tree, named
        // correctly, and empty — so the harness draws the rows the way the
        // screen does rather than the way that was convenient.
        let rotors = try await rotors(
            of: NavigationStack {
                List {
                    ForEach(lines) { row in
                        NavigationLink(value: row) { LogRowView(row: row) }
                    }
                }
                .logsRotor(problems: lines.filter(\.severity.isProblem))
            },
            waitingFor: "Errors and fatals"
        )

        let problems = try #require(rotors["Errors and fatals"])
        #expect(problems.count == problemIDs.count)

        // What comes back is the *target element's* label, which is
        // `LogRowView`'s own `spokenSummary` — measured, and worth recording:
        // `itemSearchBlock` hands VoiceOver an element, so the `entryLabel` key
        // path is what SwiftUI matches on, not what the user hears. Both have to
        // be right; only one of them is audible.
        // `LogSeverity.title` is upper-case — "ERROR", "FATAL" — which is what
        // the pill on the row reads and therefore what the row speaks.
        for label in problems {
            #expect(
                label.hasPrefix("ERROR,") || label.hasPrefix("FATAL,"),
                "a rotor entry landed on a row that is not a problem: \(label)"
            )
        }
        // A genuine subset: the list holds info, debug and warn lines the rotor
        // steps over. A rotor that stopped at every row would pass every
        // assertion above and be worthless.
        #expect(problems.count < lines.count)
    }

    // MARK: - Events

    /// Demo mode answers every `/query/` with one five-row HogQL fixture that
    /// carries no `uuid` and no `$exception`, so the feed there has nothing to
    /// jump between. These rows are the shapes `EventRow(row:)` produces.
    /// Decoded from a `/query/` payload rather than constructed, so the rows are
    /// produced by the same `EventRow(row:)` path the feed itself uses.
    private static let feedRows: [EventRow] = {
        let stamp = ISO8601DateFormatter()
        func row(_ event: String, _ minutesAgo: Int) -> String {
            let when = stamp.string(from: Date().addingTimeInterval(-60 * Double(minutesAgo)))
            return #"["e-\#(event)-\#(minutesAgo)", "\#(event)", "\#(when)", "person-1"]"#
        }
        let json = """
        {"columns": ["uuid", "event", "timestamp", "distinct_id"], "results": [
          \(row("$pageview", 1)),
          \(row("checkout_completed", 2)),
          \(row("$exception", 3)),
          \(row("$autocapture", 45)),
          \(row("signup_started", 50))
        ]}
        """
        // swiftlint:disable:next force_try
        let response = try! JSONDecoder().decode(QueryResponse.self, from: Data(json.utf8))
        return response.rows.compactMap(EventRow.init(row:))
    }()

    @Test("the events feed offers rotors for errors, custom events and time periods")
    func eventsRotors() async throws {
        let store = EventsStore()
        store.events = Self.feedRows

        let rotors = try await rotors(
            of: NavigationStack {
                List {
                    ForEach(store.buckets, id: \.title) { bucket in
                        Section(bucket.title) {
                            ForEach(bucket.events) { event in
                                NavigationLink(value: event) { EventRowView(event: event) }
                            }
                        }
                    }
                }
                .eventFeedRotors(
                    exceptions: store.exceptionRows,
                    custom: store.customEventRows,
                    periods: store.bucketAnchors
                )
            },
            waitingFor: "Custom events"
        )

        // The rotor exists to find the instrumented rows in a feed that is
        // mostly PostHog's own autocapture, so what matters is that it lands on
        // those and steps over the `$`-prefixed noise.
        let custom = try #require(rotors["Custom events"])
        #expect(custom.count == 2)
        #expect(custom.allSatisfy { !$0.contains("$") })

        let errors = try #require(rotors["Errors"])
        #expect(errors.count == 1)
        // The row's display name, not the raw `$exception`: the feed and the
        // session timeline now share one humaniser, and the rotor reads what
        // the row shows.
        #expect(errors.first?.contains("Exception") == true)

        // Two buckets in these rows — two of them minutes old, two of them
        // three-quarters of an hour — so the rotor has somewhere to go.
        let periods = try #require(rotors["Time periods"])
        #expect(periods.count == store.buckets.count)
        #expect(periods.count > 1)
    }

    // MARK: - Errors

    @Test("the error issue list offers a rotor over the unresolved issues")
    func errorTrackingRotor() async throws {
        let rotors = try await rotors(
            of: NavigationStack { ErrorTrackingRoot() },
            waitingFor: "Unresolved issues"
        )

        let unresolved = try #require(rotors["Unresolved issues"])
        #expect(!unresolved.isEmpty)
        // Resolved and suppressed issues are in the list — the status filter
        // defaults to "All" — and must not be in the rotor. Every row's label
        // ends with its status, which is what makes this checkable from the
        // rendered tree rather than from the model.
        for label in unresolved {
            #expect(
                !label.hasSuffix("Resolved") && !label.hasSuffix("Suppressed"),
                "a rotor entry landed on an issue nobody has to look at: \(label)"
            )
        }
    }

    // MARK: - Search

    @Test("the search screen offers a rotor over every screen the tab bar cannot hold")
    func searchScreensRotor() async throws {
        let rotors = try await rotors(
            of: NavigationStack { ProjectSearchView() },
            waitingFor: "Screens",
            compact: true
        )

        let screens = try #require(rotors["Screens"])

        // **The rotor enumerates the rows the list has realized, not the whole
        // array it was handed, and that is a real measurement rather than a
        // caveat.** Driven synchronously on a 393×852 window this returns the
        // first 8 of the 31 screens in `AppTab.secondary` — one screenful. A
        // `List` is lazy, `itemSearchBlock` resolves an entry to a *rendered*
        // element, and VoiceOver gets the rest because moving focus scrolls the
        // list and realizes the next cells; a loop that never scrolls does not.
        //
        // So what is asserted is the part that is observable and the part that
        // can actually be wrong: that the entries are the screen titles, in the
        // order `ScreenIndexSections` draws them, starting at the top. An entry
        // list that had drifted out of that order — or that pointed at rows no
        // longer rendered — would fail here.
        #expect(!screens.isEmpty)
        // Read from the preference rather than a static, because the index is
        // the *complement* of the tab bar: a screen the user promoted is not
        // drawn here, so a rotor entry for it would resolve to nothing.
        let indexed = Self.navPreferences().indexedScreens
        #expect(screens == Array(indexed.map(\.title).prefix(screens.count)))
        #expect(screens.first == indexed.first?.title)
    }

    // MARK: - Harness

    /// A default bar, from a defaults suite of this test's own. The screen index
    /// is the complement of the tab bar, so a stored arrangement would change
    /// which rows this harness renders.
    static func navPreferences() -> NavPreferences {
        let suite = "AccessibilityRotorTests"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return NavPreferences(defaults: UserDefaults(suiteName: suite)!)
    }

    /// Renders a screen against the demo fixtures and reads its rotors.
    ///
    /// - Parameter waitingFor: the rotor whose first entry marks the screen as
    ///   loaded. The demo transport sleeps 120ms per response on purpose, so
    ///   every screen genuinely passes through its loading state and a rotor
    ///   read too early would measure an empty list.
    private func rotors(
        of screen: some View,
        waitingFor name: String,
        compact: Bool = false,
        timeout: TimeInterval = 8
    ) async throws -> [String: [String]] {
        let model = AppModel(
            store: InMemoryTokenStore(credential: StoredCredential(key: "demo", region: .usCloud)),
            transport: DemoTransport()
        )
        await model.bootstrap()
        #expect(model.phase == .ready)

        let hosted = screen
            .environment(model)
            .environment(OpenDetails())
            // `ProjectSearchView` reads this non-optionally, so without it the
            // harness traps in `DynamicBody.updateValue` before any body of ours
            // runs - a crash with no GetHog frame in it.
            .environment(Self.navPreferences())
            .environment(\.horizontalSizeClass, compact ? .compact : nil)

        let host = Self.present(AnyView(hosted))

        let deadline = Date().addingTimeInterval(timeout)
        var found: [String: [String]] = [:]
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            host.view.layoutIfNeeded()
            found = Self.readRotors(from: host.view)
            if let entries = found[name], !entries.isEmpty { return found }
        }
        Issue.record(
            """
            '\(name)' never appeared with any entries. \
            Rotors found: \(found.keys.sorted()). \
            Tree: \(Self.labels(in: host.view).prefix(25)).
            """
        )
        return found
    }

    /// The one window every case in this suite renders into.
    ///
    /// A window per test does not work, and the reason is worth writing down:
    /// UIKit builds an accessibility tree for the **key** window, so a second
    /// detached `UIWindow` with `isHidden = false` is laid out, hit-testable and
    /// completely invisible to `accessibilityElements` — which is what a first
    /// version of this file measured, intermittently, depending on which test
    /// happened to run first. One key window attached to the process's real
    /// scene, reused, is what makes the reading deterministic.
    private static let window: UIWindow = {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.makeKeyAndVisible()
        // Without this UIKit never builds an accessibility tree in a process no
        // assistive technology has attached to, and every rotor read comes back
        // empty — measured, and the single reason the first version of this file
        // passed vacuously.
        UIApplication.shared.accessibilityActivate()
        return window
    }()

    private static func present(_ view: AnyView) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.layoutIfNeeded()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        UIApplication.shared.accessibilityActivate()
        return host
    }

    // MARK: Reading the tree

    /// Every custom rotor in the tree, driven to exhaustion.
    ///
    /// `itemSearchBlock` is UIKit's own contract with VoiceOver: hand it the
    /// current item and a direction, get the next one back or nil at the end.
    /// Calling it in a loop is exactly what a user flicking down with the rotor
    /// set to "Errors" does, which is why the result is evidence rather than a
    /// restatement of the array the modifier was given.
    static func readRotors(from root: UIView) -> [String: [String]] {
        var byName: [String: [String]] = [:]
        var objects: [NSObject] = []
        collectObjects(from: root, depth: 0, into: &objects, seen: NSHashTable.weakObjects())

        for object in objects {
            guard let rotors = object.accessibilityCustomRotors else { continue }
            for rotor in rotors {
                let name = rotor.name
                // The same rotor is reachable by several paths through the tree
                // (a view's subviews and its accessibility elements overlap), so
                // the richest reading wins rather than the last one.
                let entries = drive(rotor, from: object)
                if entries.count >= (byName[name]?.count ?? -1) { byName[name] = entries }
            }
        }
        return byName
    }

    private static func drive(
        _ rotor: UIAccessibilityCustomRotor,
        from origin: NSObject,
        limit: Int = 200
    ) -> [String] {
        var labels: [String] = []
        var predicate = UIAccessibilityCustomRotorSearchPredicate()
        predicate.searchDirection = .next
        predicate.currentItem = UIAccessibilityCustomRotorItemResult(
            targetElement: origin, targetRange: nil
        )
        while labels.count < limit, let result = rotor.itemSearchBlock(predicate) {
            let element = result.targetElement as? NSObject
            labels.append(element?.accessibilityLabel ?? "")
            predicate.currentItem = result
        }
        return labels
    }

    private static func collectObjects(
        from object: NSObject,
        depth: Int,
        into found: inout [NSObject],
        seen: NSHashTable<NSObject>
    ) {
        guard depth < 40, !seen.contains(object) else { return }
        seen.add(object)
        found.append(object)

        if let view = object as? UIView {
            for sub in view.subviews {
                collectObjects(from: sub, depth: depth + 1, into: &found, seen: seen)
            }
        }
        if let elements = object.accessibilityElements as? [NSObject] {
            for element in elements {
                collectObjects(from: element, depth: depth + 1, into: &found, seen: seen)
            }
        }
        let count = object.accessibilityElementCount()
        if count != NSNotFound {
            for index in 0..<min(count, 120) {
                if let element = object.accessibilityElement(at: index) as? NSObject {
                    collectObjects(from: element, depth: depth + 1, into: &found, seen: seen)
                }
            }
        }
    }

    /// Every accessibility label in the rendered tree.
    static func labels(in root: UIView) -> [String] {
        var objects: [NSObject] = []
        collectObjects(from: root, depth: 0, into: &objects, seen: NSHashTable.weakObjects())
        return objects.compactMap(\.accessibilityLabel)
    }
}
