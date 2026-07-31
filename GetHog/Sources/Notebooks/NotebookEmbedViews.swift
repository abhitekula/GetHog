import GetHogKit
import SwiftUI

// Embedded PostHog objects inside a notebook.
//
// `NotebookNodeType.rendering` decides which of three promises each block makes,
// and the split is stated in the model rather than discovered here so that the
// reader is told *which kind of incomplete* they are looking at:
//
// - `.full`    — the block's own content appears: a real chart, the author's
//                own code or formula, a real image.
// - `.summary` — the object is named and openable, but what the console draws
//                inside the block is not reproduced. A flag block in the console
//                shows the rollout and the variants; here it shows the flag and
//                a way to its screen.
// - `.nameOnly`— the block is named and nothing more. These are the
//                customer-analytics panels and the Zendesk/support integrations:
//                no phone equivalent exists and no id is worth chasing.

struct NotebookEmbedRow: View {
    let embed: NotebookEmbed
    let insightCache: NotebookInsightCache

    var body: some View {
        switch embed.type {
        case .query:
            NotebookInsightBlock(embed: embed, cache: insightCache)
        case .recording:
            NotebookRecordingBlock(embed: embed)
        case .image:
            NotebookImageBlock(embed: embed)
        case .latex:
            NotebookFormulaBlock(embed: embed)
        case .hogqlSQL, .duckSQL, .sqlV2, .python, .pythonV2:
            NotebookSourceBlock(embed: embed)
        case .taskCreate:
            NotebookTaskBlock(embed: embed)
        default:
            NotebookReferenceCard(embed: embed)
        }
    }
}

// MARK: - Embedded insight

/// An embedded insight, and the whole rate-limit decision made visible.
///
/// PostHog's limits are **organisation-wide** and shared with whatever else the
/// user has integrated, so a notebook with twelve embedded insights that fired
/// twelve `/query/` requests on appear would spend a fifth of a minute's entire
/// `.query` allowance (60/min) on a screen the reader merely scrolled past — and
/// spend it against their production budget. That is ruled out. What replaces it
/// is not a compromise but a consequence of what the API actually offers:
///
/// **A saved insight is read, not computed.** `GET /insights/?short_id=…&limit=1`
/// is `.crud` and — measured against project [REMOVED PRIVATE DATA] on 2026-07-30 — never
/// triggers a computation. Three insights whose results were cold came back in
/// 0.15–0.28s still `result: null`, `is_cached: false`, with no `query_status`;
/// a warm one came back with its result populated. So it is safe to issue on
/// appear: it yields either a real chart from the server's own cache or the
/// honest news that there isn't one, and offers to run it.
///
/// **An inline query has no cache anywhere.** Nothing has computed it under that
/// identity, so drawing it *requires* a `POST /query/`. That waits for a tap —
/// the same rule `DashboardDetailStore` follows for re-running a dashboard over
/// a new range, and `SavedInsightStore` for escalating to `computeInsight`.
///
/// The blocks are independent, so a reader who wants three of the twelve pays
/// for three.
@MainActor
@Observable
final class NotebookInsightStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready(InsightRenderModel)
        /// Fetched, but the server had no computed result to give.
        case notComputed
        case failed(String)
    }

    var phase: Phase = .idle
    /// The insight's own name, once known — a notebook block often has no title
    /// of its own and the saved insight's name is the better label.
    var resolvedTitle: String?
    var linkID: String?

    private var sourceKind: String?
    private var display: String?
    /// The saved insight's numeric id, kept so a cold one can be computed.
    ///
    /// Without it the "Run it" button on a `.notComputed` block would re-read the
    /// same empty cache and land back on the same card — a control that appears
    /// to work and changes nothing.
    private var insightID: Int?

    /// The cheap half: fetch the saved insight and draw whatever the server has.
    func loadSavedInsight(
        shortID: String,
        client: PostHogClient,
        projectID: Int
    ) async {
        guard case .idle = phase else { return }
        phase = .loading
        do {
            let page: Page<Insight> = try await client.send(
                PostHogAPI.insight(projectID: projectID, shortID: shortID)
            )
            guard let insight = page.results.first else {
                // An unknown handle is an empty page, not a 404, so this really
                // is "no such insight" rather than "the request failed".
                phase = .failed("That insight no longer exists in this project.")
                return
            }
            resolvedTitle = insight.title
            linkID = insight.linkID
            sourceKind = insight.sourceKind
            display = insight.displayType
            insightID = insight.id
            // `hasDrawableResult` is true for `.unsupported` on purpose: a kind
            // with no chart here is settled, and running it would change nothing.
            phase = insight.hasDrawableResult ? .ready(insight.renderModel) : .notComputed
        } catch {
            phase = .failed(LoadFailure(error, loading: "insight").summary)
        }
    }

    /// The expensive half, and only ever from a tap.
    func run(
        source: JSONValue,
        kind: String,
        display: String?,
        client: PostHogClient,
        projectID: Int
    ) async {
        phase = .loading
        sourceKind = kind
        self.display = display
        do {
            let data = try await client.data(
                for: PostHogAPI.runQuery(projectID: projectID, source: source)
            )
            if let model = InsightRerun.renderModel(from: data, sourceKind: kind, display: display) {
                phase = .ready(model)
            } else {
                phase = .failed("PostHog's response wasn't in a shape this app could draw.")
            }
        } catch {
            phase = .failed(LoadFailure(error, loading: "query").summary)
        }
    }

    /// Computes a saved insight PostHog had no cached result for.
    ///
    /// `computeInsight` rather than `/query/`: it is `refresh=blocking` on the
    /// insight's own endpoint, so PostHog runs the saved query as saved and this
    /// app does not have to reconstruct it — and it bills `.analytics` (180/min)
    /// instead of `.query` (60/min), leaving the scarcer budget for the inline
    /// queries that have no other route. Same escalation `SavedInsightStore`
    /// makes, and like it, only from a tap.
    func compute(client: PostHogClient, projectID: Int) async {
        guard let insightID else { return }
        phase = .loading
        do {
            let insight: Insight = try await client.send(
                PostHogAPI.computeInsight(projectID: projectID, insightID: insightID)
            )
            phase = insight.hasDrawableResult ? .ready(insight.renderModel) : .notComputed
        } catch {
            phase = .failed(LoadFailure(error, loading: "insight").summary)
        }
    }
}

/// One store per embedded insight, owned by the screen rather than by the row.
///
/// **This is a rate-limit fix, not tidiness.** A `List` recycles its rows, so
/// `@State` on the block is destroyed when it scrolls far enough off screen and
/// rebuilt — at `.idle` — when it comes back, and the `.task` fires again. On a
/// long notebook that turns "one request per embedded insight" into "one per
/// insight per time the reader scrolls past it", which is exactly the
/// organisation-wide budget this design exists to protect. Holding the stores
/// above the `List` makes a completed fetch survive recycling.
@MainActor
@Observable
final class NotebookInsightCache {
    private var stores: [String: NotebookInsightStore] = [:]

    func store(for key: String) -> NotebookInsightStore {
        if let existing = stores[key] { return existing }
        let created = NotebookInsightStore()
        stores[key] = created
        return created
    }
}

// Passed down explicitly rather than through the environment: an `EnvironmentKey`
// must supply a `nonisolated` default, and this cache is `@MainActor`. Making it
// optional to satisfy that would mean a host forgetting to install one degrades
// silently back to per-row state — the exact re-fetch-on-scroll bug the cache
// exists to prevent. A required parameter cannot be forgotten.

struct NotebookInsightBlock: View {
    let embed: NotebookEmbed
    let cache: NotebookInsightCache

    @Environment(AppModel.self) private var model

    /// `nodeId` is the block's durable identity — the console assigns it and the
    /// notebook stores it, and `/sql_v2/state/` calls it "durable cell identity".
    /// The fallback covers a hand-assembled document with none; two such blocks
    /// referencing the same insight would share a store, which is harmless
    /// because they would fetch the same thing.
    private var storeKey: String {
        embed.attrs["nodeId"]?.stringValue
            ?? embed.savedInsightShortID
            ?? String(describing: embed.attrs["query"])
    }

    private var store: NotebookInsightStore { cache.store(for: storeKey) }

    private var plan: NotebookInsightPlan? { NotebookInsightPlan(embed: embed) }

    private var title: String {
        embed.title ?? store.resolvedTitle ?? "Embedded insight"
    }

    private var webURL: URL? {
        store.linkID.flatMap { model.webURL(path: "insights/\($0)") }
    }

    var body: some View {
        Card(accent: Theme.accent) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                CardHeader(title: title, systemImage: NotebookNodeType.query.glyph, subtitle: subtitle)
                content
            }
        }
        .task {
            // Only the cheap plan runs here. `runOnRequest` deliberately does
            // nothing on appear — see the type's documentation.
            guard case .fetchSavedInsight(let shortID)? = plan,
                  let client = model.client, let projectID = model.projectID
            else { return }
            await store.loadSavedInsight(shortID: shortID, client: client, projectID: projectID)
        }
    }

    private var subtitle: String? {
        switch plan {
        case .fetchSavedInsight: nil
        case .runOnRequest(_, let kind, _): kind.replacingOccurrences(of: "Query", with: "")
        case nil: nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .ready(let renderModel):
            InsightChartView(model: renderModel, compact: true, webURL: webURL, title: title)

        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.xl)

        case .failed(let message):
            NotebookBlockNotice(
                symbol: "exclamationmark.triangle",
                message: message,
                actionTitle: "Try again",
                action: retry
            )

        case .notComputed:
            // Distinguished from an error on purpose. Nothing failed: PostHog
            // simply has no cached numbers for this insight, and computing them
            // costs a `/query/` slot that the reader should choose to spend.
            NotebookBlockNotice(
                symbol: "clock.arrow.circlepath",
                message: "PostHog has no stored result for this insight. Computing it now costs one request against your organisation's shared rate limit.",
                actionTitle: "Run it",
                action: retry
            )

        case .idle:
            idleState
        }
    }

    @ViewBuilder
    private var idleState: some View {
        switch plan {
        case .runOnRequest(_, let kind, _):
            NotebookBlockNotice(
                symbol: "play.circle",
                message: "This block holds a \(kind.replacingOccurrences(of: "Query", with: "").lowercased()) query written into the notebook rather than a saved insight, so there is no stored result to show. Running it costs one query against your organisation's shared rate limit.",
                actionTitle: "Run query",
                action: retry
            )
        case .fetchSavedInsight:
            // The `.task` is about to replace this; a skeleton avoids a flash of
            // explanatory text for something that resolves in a fifth of a second.
            Color.clear.frame(height: 80).skeleton(true)
        case nil:
            // A query node whose `query` attribute this build could not read.
            // Still a block the author put there, so it still says so.
            NotebookBlockNotice(
                symbol: "questionmark.square.dashed",
                message: "This block holds a query GetHog couldn't read. Open the notebook in PostHog to see it.",
                actionTitle: nil,
                action: nil
            )
        }
    }

    private func retry() {
        guard let client = model.client, let projectID = model.projectID else { return }
        Task {
            switch plan {
            case .runOnRequest(let source, let kind, let display):
                await store.run(source: source, kind: kind, display: display,
                                client: client, projectID: projectID)
            case .fetchSavedInsight(let shortID):
                // Two different retries behind one button, because they answer
                // two different failures. After `.notComputed` the cache is
                // known-empty and re-reading it would land on the same card, so
                // the tap computes — which is why the card says what that costs
                // before it is tapped. After `.failed` the request itself went
                // wrong, and repeating the cheap read is the right first move.
                if case .notComputed = store.phase {
                    await store.compute(client: client, projectID: projectID)
                } else {
                    store.phase = .idle
                    await store.loadSavedInsight(shortID: shortID, client: client, projectID: projectID)
                }
            case nil:
                break
            }
        }
    }
}

// MARK: - Embedded recording

/// Opens a recording in the app's own replay screen.
///
/// Set by `NotebookDetailView`, which owns the destination, so the block itself
/// stays free of navigation. `nil` where no host offers one — the block then
/// falls back to the console link rather than showing a button that does
/// nothing.
struct NotebookRecordingOpener: EnvironmentKey {
    static let defaultValue: (@MainActor (SessionRecording) -> Void)? = nil
}

extension EnvironmentValues {
    var notebookRecordingOpener: (@MainActor (SessionRecording) -> Void)? {
        get { self[NotebookRecordingOpener.self] }
        set { self[NotebookRecordingOpener.self] = newValue }
    }
}

/// An embedded session recording.
///
/// The player is **not** mounted inline, and that is the same budget argument as
/// the inline query. Playing a recording costs the recording's metadata
/// (`.analytics`) and then a stream of snapshot blobs; a notebook written around
/// four replays would start four of those on appear, and rrweb players are not
/// cheap to have four of on a phone besides. So the block identifies the
/// recording for free and the reader chooses which one to open — at which point
/// they get the real player, transport, console and network panes, not a link
/// out to a browser.
private struct NotebookRecordingBlock: View {
    let embed: NotebookEmbed

    @Environment(AppModel.self) private var model
    @Environment(\.notebookRecordingOpener) private var open
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        Card(accent: Theme.accentWarm) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(
                    title: embed.title ?? "Session recording",
                    systemImage: NotebookNodeType.recording.glyph,
                    subtitle: startLabel
                )

                if let id = embed.recordingID {
                    Text(id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if let failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Theme.Status.criticalInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if embed.recordingID == nil {
                    Text("This block points at a recording GetHog couldn't identify.")
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                } else if open != nil {
                    Button(action: load) {
                        Label(
                            isLoading ? "Opening…" : "Play recording",
                            systemImage: "play.fill"
                        )
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                } else if let url = consoleURL {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.medium))
                            .frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
    }

    private var startLabel: String? {
        guard let ms = embed.recordingStartMs, ms > 0 else { return nil }
        return "From \(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond)))"
    }

    private var consoleURL: URL? {
        embed.recordingID.flatMap { model.webURL(path: "replay/\($0)") }
    }

    /// One `.analytics` request, from a tap. The replay screen it pushes fetches
    /// its own snapshots — which is exactly why that is not done here.
    private func load() {
        guard let id = embed.recordingID,
              let client = model.client,
              let projectID = model.projectID,
              let open
        else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let recording: SessionRecording = try await client.send(
                    PostHogAPI.sessionRecording(projectID: projectID, recordingID: id)
                )
                failure = nil
                open(recording)
            } catch {
                failure = LoadFailure(error, loading: "recording").summary
            }
        }
    }
}

// MARK: - Simple full-fidelity blocks

private struct NotebookImageBlock: View {
    let embed: NotebookEmbed

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let source = embed.imageSource, let url = URL(string: source) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .clipShape(.rect(cornerRadius: Theme.Radius.small, style: .continuous))
                    case .failure:
                        NotebookBlockNotice(
                            symbol: "photo.badge.exclamationmark",
                            message: "This image couldn't be loaded from \(url.host() ?? source).",
                            actionTitle: nil, action: nil
                        )
                    default:
                        Color.clear.frame(height: 120).skeleton(true)
                    }
                }
            } else {
                // A `ph-image` whose bytes live in PostHog's own storage arrives
                // under `file` rather than `src`, and this app has no verified
                // way to resolve that reference — so it says so rather than
                // showing a broken frame.
                NotebookBlockNotice(
                    symbol: "photo",
                    message: "This image is stored in PostHog and GetHog can't fetch it. Open the notebook in PostHog to see it.",
                    actionTitle: nil, action: nil
                )
            }
            if let title = embed.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(embed.title.map { "Image. \($0)" } ?? "Image")
    }
}

private struct NotebookFormulaBlock: View {
    let embed: NotebookEmbed

    var body: some View {
        // The formula's LaTeX source, not typeset output. Typesetting LaTeX
        // needs a renderer this app does not carry, and the source is what the
        // author wrote — legible for anything short of a matrix, and honest
        // about what it is.
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(embed.latexFormula ?? "")
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text("LaTeX source — GetHog doesn't typeset formulas.")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.pageBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Formula, LaTeX source. \(embed.latexFormula ?? "")")
    }
}

/// A code node — HogQL, DuckDB SQL or Python.
///
/// The source is shown; the *result* is not. These nodes cache their last run in
/// the notebook itself (`hogqlExecution`, `pythonExecution`, `result`), but this
/// build has never seen one populated — project [REMOVED PRIVATE DATA] has no notebooks — so
/// decoding those attributes would be a claim with nothing behind it. Re-running
/// them is out of scope twice over: a HogQL run costs a `/query/`, and a Python
/// run needs the notebook's sandbox kernel started.
private struct NotebookSourceBlock: View {
    let embed: NotebookEmbed

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(embed.sourceLanguage ?? embed.type.label, systemImage: embed.type.glyph)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Ink.secondary)
                Spacer()
            }
            if let code = embed.sourceCode {
                // Wrapping, not horizontal scrolling — same reasoning as
                // `NotebookCodeBlock`, including that a `ScrollView` here is
                // invisible to `ImageRenderer` and so unverifiable.
                Text(code)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    // Without this the block truncates to two lines with an ellipsis
                    // rather than wrapping — seen in the ImageRenderer output, not
                    // guessed. A `Text` in a stack takes its ideal height unless told
                    // to grow vertically at the offered width.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Theme.pageBackground)
                    )
            }
            Text("GetHog shows this block's source, not its output.")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(embed.sourceLanguage ?? embed.type.label) block. \(embed.sourceCode ?? "No source"). Output not shown.")
    }
}

private struct NotebookTaskBlock: View {
    let embed: NotebookEmbed

    var body: some View {
        Card(accent: Theme.accentWarm) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                CardHeader(
                    title: embed.attrs["title"]?.stringValue ?? "Suggested task",
                    systemImage: NotebookNodeType.taskCreate.glyph,
                    subtitle: embed.attrs["severity"]?.stringValue
                )
                if let description = embed.attrs["description"]?.stringValue, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
    }
}

// MARK: - Reference cards

/// A block that names the object it points at.
///
/// Covers both `.summary` — where there is an id worth carrying and a link worth
/// offering — and `.nameOnly`, where there is neither. The two differ in what
/// the card can say, not in whether it appears.
struct NotebookReferenceCard: View {
    let embed: NotebookEmbed

    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(
                    title: embed.title ?? embed.type.label,
                    systemImage: embed.type.glyph,
                    subtitle: embed.title == nil ? nil : embed.type.label
                )

                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let identifier = embed.entityID ?? embed.distinctID {
                    Text(identifier)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.Ink.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let url = consoleURL {
                    Link(destination: url) {
                        Label("Open in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.footnote.weight(.medium))
                            // The tap region of a `Link` is its label, so the
                            // 44pt floor goes inside the closure.
                            .frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(embed.type.label). \(explanation)")
    }

    private var explanation: String {
        switch embed.type.rendering {
        case .summary:
            "GetHog names this \(embed.type.label.lowercased()) but doesn't reproduce the panel the notebook draws for it."
        case .nameOnly:
            "This block has no GetHog equivalent — it's a panel the PostHog console draws inside the notebook."
        case .full:
            // Unreachable in practice: every `.full` type has its own view
            // above. Kept rather than crashed on, because a future type added to
            // `.full` without a view here must still say something true.
            "GetHog can't draw this block yet."
        }
    }

    /// A console link, only where the path is one this app already builds
    /// elsewhere. A guessed path that 404s is worse than no button.
    private var consoleURL: URL? {
        guard let id = embed.entityID else { return nil }
        let path: String? = switch embed.type {
        case .featureFlag, .featureFlagCodeExample: "feature_flags/\(id)"
        case .survey: "surveys/\(id)"
        case .experiment: "experiments/\(id)"
        case .cohort: "cohorts/\(id)"
        case .earlyAccessFeature: "early_access_features/\(id)"
        case .person, .personProperties, .personFeed: "person/\(id)"
        case .recording: "replay/\(id)"
        default: nil
        }
        return path.flatMap { model.webURL(path: $0) }
    }
}

// MARK: - Shared notice

/// The small in-block message used by every block that has something to say
/// instead of content.
struct NotebookBlockNotice: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.Ink.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
    }
}
