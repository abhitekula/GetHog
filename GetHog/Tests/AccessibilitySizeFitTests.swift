import GetHogKit
import GetHogUI
import SwiftUI
import Testing
import UIKit

@testable import GetHog

/// Nothing this app draws may be wider than the phone it is drawn on.
///
/// **The defect this exists for.** At AX5 the session detail screen ran off
/// *both* edges: the avatar was half off the leading side, and `Wed, Jul 29 a`,
/// `https:`, `Desktop · Ma` and `Chrome 15` were cut on the trailing one with no
/// ellipsis and no wrap. It was also the only screen in the harness whose page
/// background went white, which is the tell — the content was wider than the
/// viewport, so the canvas behind it was never drawn.
///
/// **Why a unit test and not the audit next door.** `AccessibilityAuditTests`
/// runs Apple's audit, and it would not have caught this for two independent
/// reasons. Every case in that file launches at the *default* type size, so no
/// assertion in this repository had ever rendered these screens at AX5 at all;
/// and `textClipped` — the audit type that comes closest — is deliberately
/// excluded there, measured at 37 hits dominated by system-drawn search-field
/// placeholders. Adding it would have made that file permanently red without
/// naming this defect. A frame is not a heuristic: it is either inside the
/// window or it is not.
///
/// **Why the measurement is the scroll view's `contentSize` and not a subview's
/// frame.** Overflow does not stay where it starts. Every card on the session
/// screen shares one `VStack` inside one `ScrollView`, so a single row that
/// reports a width past the viewport widens the stack, and every sibling — and
/// the page background — is laid out to the wider measure. Measured in a 393pt
/// window before the fix: the header card was fine on its own, the summary card
/// asked for 447pt and the timeline for 413pt, and the composed screen came out
/// at 447. Asserting the container is what catches the cause wherever it sits.
///
/// **Each card is measured alone as well as composed**, so a failure names the
/// card rather than the screen.
@Suite("Accessibility-size layout fits the phone")
@MainActor
struct AccessibilitySizeFitTests {

    /// iPhone 17 Pro's points, which is what the screenshot harness renders.
    private static let phoneWidth: CGFloat = 393

    /// A third of a point of slack, for the same reason `assertMeetsMinimumHitTarget`
    /// allows a hundredth: these widths arrive as thirds after a float round trip
    /// (`393.3333…`), and a bare `==` fails on a layout that is exactly right.
    private static let slack: CGFloat = 0.5

    private static let replayable = "018f1000-0000-7000-8000-000000000001"

    // MARK: - Harness

    private func client() -> PostHogClient {
        PostHogClient(
            auth: PersonalKeyAuthProvider(key: "demo", region: .usCloud),
            transport: DemoTransport()
        )
    }

    private func recording() async throws -> SessionRecording {
        let page: Page<SessionRecording> = try await client().send(
            PostHogAPI.sessionRecordings(projectID: 1_001)
        )
        return try #require(page.results.first { $0.id == Self.replayable })
    }

    /// The window this is all measured in. 852 is the iPhone 17 Pro's height, and
    /// it is load-bearing for `expectStaysChrome` rather than decoration.
    private static let phoneHeight: CGFloat = 852

    /// Lays a view out in a real window at AX5 and returns how large its scrolling
    /// content actually came out.
    ///
    /// A real `UIWindow` rather than `UIHostingController.sizeThatFits`, which
    /// answers the *proposal* for anything carrying `frame(maxWidth: .infinity)`
    /// — every `Card` in this app — and so reported 393 for the very screen that
    /// was visibly running off both edges.
    private func contentSize(of view: some View) -> CGSize {
        let host = UIHostingController(
            rootView: view
                .environment(AppModel(store: InMemoryTokenStore(), transport: DemoTransport()))
                .environment(\.dynamicTypeSize, .accessibility5)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.phoneWidth, height: Self.phoneHeight))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        func outermostScrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for subview in view.subviews {
                if let scroll = outermostScrollView(subview) { return scroll }
            }
            return nil
        }
        guard let scroll = outermostScrollView(host.view) else {
            return CGSize(width: -1, height: -1)
        }
        return scroll.contentSize
    }

    private func contentWidth(of view: some View) -> CGFloat {
        contentSize(of: view).width
    }

    /// Wraps a card the way the session screen does, so the measurement is of the
    /// card in its own page rather than of a view pinned to the window's width.
    private func page(_ view: some View) -> some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) { view }
                .padding(.vertical, Theme.Space.l)
        }
    }

    private func expectFits(_ what: String, _ view: some View) {
        let width = contentWidth(of: view)
        let message: Testing.Comment = """
            \(what) lays out \(width)pt wide in a \(Self.phoneWidth)pt window at AX5. \
            Everything sharing its stack is laid out to that width too, including \
            the page background.
            """
        #expect(width <= Self.phoneWidth + Self.slack, message)
    }

    /// A filter bar is chrome, and chrome that outgrows the window has stopped
    /// being chrome.
    ///
    /// **Why height and not width.** `GlassFilterBar` never overflowed: it is a
    /// row of controls inside a container that fills the width it is offered, so
    /// `expectFits` was green on it throughout. What it did instead was *grow
    /// downwards* — with two controls dividing 393pt between them at AX5, each got
    /// a column narrower than its own label, and every extra line one of them
    /// wrapped to made the bar taller. Measured in this window on the Insights
    /// pair (a kind menu and a `Favorites` toggle): **559.3pt before the reflow
    /// and 272.7pt after**, against a window 852pt tall. The screenshot sweep
    /// described the same thing from the other side — a "Favorites" toggle
    /// wrapped one or two characters per line into a roughly 700pt-tall capsule,
    /// with the filter card filling 40% of the window.
    ///
    /// **Half the window is the rule, not the measurement.** The number is not
    /// tuned to sit between 559 and 273: it says that a bar naming which subset of
    /// the data is on screen must not take more of the screen than the data does.
    /// A bar that needs more than that has stopped being a filter and become the
    /// page. The three bars in this app's scope measure 272.7, 200.0 and 192.0
    /// against a 426pt ceiling.
    private func expectStaysChrome(_ what: String, _ view: some View) {
        let height = contentSize(of: view).height
        let ceiling = Self.phoneHeight / 2
        let message: Testing.Comment = """
            \(what) lays out \(height)pt tall in a \(Self.phoneHeight)pt window at AX5, \
            past the \(ceiling)pt a filter bar is allowed. A bar this tall is not \
            chrome above the data — it is the page, with the data under it.
            """
        #expect(height <= ceiling, message)
    }

    // MARK: - Session detail, card by card

    @Test("every card on the session detail screen fits an iPhone at AX5")
    func sessionDetailCardsFit() async throws {
        let recording = try await recording()

        let timeline = SessionTimelineStore()
        await timeline.load(
            client: client(),
            projectID: 1_001,
            sessionID: recording.id,
            window: Date().addingTimeInterval(-864_000)...Date()
        )
        let summary = ReplayVisionSummaryStore()
        await summary.load(client: client(), projectID: 1_001, sessionID: recording.id)
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: recording)

        // The fixtures have to be populated, or this measures empty cards and
        // passes on a broken loaded-state layout.
        #expect(!timeline.events.isEmpty)
        if case .loaded = summary.state {} else {
            Issue.record("The demo session's Replay Vision summary did not load.")
        }

        expectFits("The session header card", page(
            SessionHeaderCard(
                recording: recording,
                environment: SessionEnvironment(events: timeline.events, person: recording.person)
            )
            .padding(.horizontal, Theme.Space.l)
        ))

        expectFits("The session summary card", page(
            SessionSummaryCard(store: summary, canSeek: true)
                .padding(.horizontal, Theme.Space.l)
        ))

        expectFits("The session timeline", page(
            SessionTimelineView(recording: recording, store: timeline, canSeek: true)
                .padding(.horizontal, Theme.Space.l)
        ))

        expectFits("The replay player", page(
            ReplayPlayerView(
                recording: recording, loader: loader, controller: ReplayPlayerController()
            )
            .padding(.horizontal, Theme.Space.l)
        ))

        expectFits("The replay console pane", page(
            ReplayConsoleCard(
                diagnostics: loader.diagnostics, origin: loader.replayStart, playhead: 0
            )
            .padding(.horizontal, Theme.Space.l)
        ))

        expectFits("The replay network pane", page(
            ReplayNetworkCard(
                diagnostics: loader.diagnostics,
                origin: loader.replayStart,
                duration: 3269,
                playhead: 0
            )
            .padding(.horizontal, Theme.Space.l)
        ))
    }

    /// The composed screen, because that is where the defect was visible: the
    /// widest card sets the width of the page and of every card beside it.
    @Test("the whole session detail stack fits an iPhone at AX5")
    func sessionDetailStackFits() async throws {
        let recording = try await recording()

        let timeline = SessionTimelineStore()
        await timeline.load(
            client: client(),
            projectID: 1_001,
            sessionID: recording.id,
            window: Date().addingTimeInterval(-864_000)...Date()
        )
        let summary = ReplayVisionSummaryStore()
        await summary.load(client: client(), projectID: 1_001, sessionID: recording.id)
        let loader = ReplayLoader()
        await loader.start(client: client(), projectID: 1_001, recording: recording)

        expectFits("The session detail screen", ScrollView {
            VStack(spacing: Theme.Space.l) {
                SessionHeaderCard(
                    recording: recording,
                    environment: SessionEnvironment(events: timeline.events, person: recording.person)
                )
                .padding(.horizontal, Theme.Space.l)

                StatStrip {
                    MetricTile(label: "Clicks", value: "39", compact: true)
                    MetricTile(label: "Keypresses", value: "64", compact: true)
                    MetricTile(label: "Console errors", value: "0", compact: true)
                    MetricTile(label: "Active", value: "1:28", compact: true)
                }

                ReplayPlayerView(
                    recording: recording, loader: loader, controller: ReplayPlayerController()
                )
                .padding(.horizontal, Theme.Space.l)

                SessionSummaryCard(store: summary, canSeek: true)
                    .padding(.horizontal, Theme.Space.l)

                SessionTimelineView(recording: recording, store: timeline, canSeek: true)
                    .padding(.horizontal, Theme.Space.l)

                FreshnessLabel(date: timeline.loadedAt)
            }
            .padding(.vertical, Theme.Space.l)
        }
        .pageSurface())
    }

    // MARK: - The other screen with a two-column row

    /// Taxonomy's two stat tiles were the other side-by-side pair that stayed
    /// side by side at AX5. It did not overflow the way the session screen did —
    /// a `MetricTile` compresses — but it is the same shape and the same fix, and
    /// pinning it here is what stops the reflow being dropped later.
    @Test("the taxonomy summary card fits an iPhone at AX5")
    func taxonomySummaryFits() {
        expectFits("Taxonomy's summary card", page(
            TaxonomySummaryCard(activeCount: 63, definedCount: 75)
                .padding(.horizontal, Theme.Space.l)
        ))
    }

    // MARK: - The header card that emptied itself

    /// **The defect.** At AX5 the session summary's header card drew a circle-✕
    /// and a `2 exceptions` pill in a field of white and nothing else: the
    /// `Did not finish` outcome and the whole summary paragraph were gone from the
    /// screen — not truncated, absent.
    ///
    /// The cause is a width, which is why the existing `expectFits` is the right
    /// assertion and not a new one. `StatusPill` carried an unconditional
    /// `fixedSize()`, and `fixedSize` is a demand on the layout rather than a
    /// local preference: an `HStack` satisfies it before it gives anything to a
    /// flexible sibling. At AX5 `2 exceptions` is around 350pt of a 393pt phone,
    /// so the heading beside it was offered a column narrower than one character —
    /// it rendered nothing while still claiming a line's height per character it
    /// could not draw, and the paragraph below was pushed off the bottom.
    ///
    /// Measured in this harness: **the pre-fix header card laid out 406.3pt wide
    /// in a 393pt window**, so it was overflowing as well as emptying itself, and
    /// this assertion fails on the old shape. It is 393.0 now.
    @Test("the session summary detail screen fits an iPhone at AX5")
    func sessionSummaryDetailFits() async throws {
        let response: QueryResponse = try await client().send(
            PostHogAPI.replayVisionSummaryDigests(projectID: 1_001)
        )
        let row = try #require(ReplayVisionSummaryDigest.rows(from: response).first)
        expectFits("The session summary detail screen", self.page(
            ReplayVisionSummaryDetailView(row: row)
        ))
    }

    /// The other card built the same way, and the honest note about it.
    ///
    /// Render detail's header pairs `MP4 video` with a status pill, and at AX5 the
    /// pill's refusal to compress broke the format name into `MP4` / `vide` / `o`
    /// across roughly half the card. **This assertion did not catch that**: the
    /// card compressed rather than overflowed, measuring 393.0pt wide before the
    /// fix as well as after. It is here as a guard on the reflow that replaced it,
    /// and the defect itself was confirmed by screenshot rather than by this test.
    @Test("the render detail screen fits an iPhone at AX5")
    func renderDetailFits() async throws {
        let page: Page<RecordingExport> = try await client().send(
            PostHogAPI.exports(projectID: 1_001)
        )
        let export = try #require(page.results.first)
        expectFits("The render detail screen", self.page(
            RenderDetailView(export: export, asOf: Date())
        ))
    }

    // MARK: - The filter bar that became the page

    /// `GlassFilterBar` with the two controls Insights puts in it.
    ///
    /// The content is written out here rather than reached for, because the bars
    /// themselves are `private var filterBar` on their screens. What is under test
    /// is the container: the pair is representative of what every caller hands it
    /// — one menu that takes the row's slack, one bordered toggle beside it — and
    /// the collapse was the container's, on every screen at once.
    @Test("a filter bar stays chrome at AX5 rather than becoming the page")
    func filterBarStaysChrome() {
        expectStaysChrome("Insights' filter bar", page(
            GlassFilterBar {
                Picker("Insight kind", selection: .constant(InsightKind?.none)) {
                    Text("All kinds").tag(InsightKind?.none)
                    ForEach(InsightKind.allCases) { option in
                        Text(option.title).tag(InsightKind?.some(option))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: .constant(false)) {
                    Label("Favorites", systemImage: "star")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
            }
        ))

        expectStaysChrome("Logs' filter bar", page(
            GlassFilterBar {
                Picker("Time range", selection: .constant(LogsWindow.day)) {
                    ForEach(LogsWindow.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(isOn: .constant(false)) {
                    Label("Errors only", systemImage: "exclamationmark.octagon")
                }
                .toggleStyle(.button)
                .font(.footnote)
            }
        ))

        // Ingestion's is the segmented one. `adaptivePickerStyle` is what is being
        // pinned here: as a segmented control it measured 106.7pt — it did not
        // grow at all, which is the defect, since every neighbour on the screen
        // had tripled. As a menu it is 192.0pt and legible.
        expectStaysChrome("Ingestion's filter bar", page(
            GlassFilterBar {
                Picker("Window", selection: .constant(IngestionWarningWindow.sevenDays)) {
                    ForEach(IngestionWarningWindow.allCases) { window in
                        Text(window.shortTitle).tag(window)
                    }
                }
                .adaptivePickerStyle()
                .frame(maxWidth: .infinity, alignment: .leading)

                Label("All", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
                    .lineLimit(1)
            }
        ))
    }
}
