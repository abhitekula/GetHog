import GetHogKit
import SwiftUI

// The warehouse's modelling half on screen: the views a team defines on top of
// its warehouse tables, and whether the tables behind them are current.
//
// `WarehouseRoot` owns the list section and the alert banner; this file owns
// the store, the row, and the detail screen. The split is the same one
// `WarehouseRoot` already makes for sources and tables — the root is the screen,
// each half brings its own store — and it keeps the root's diff to a section and
// a selection case.

// MARK: - Store

/// Saved queries for the project, loaded once per screen.
///
/// Separate from `WarehouseStore` rather than a third `do` block inside it,
/// because this list can fail on its own: a project on a plan without data
/// modelling still has sources and tables, and a failure here must leave both on
/// screen. `WarehouseRoot` composes the two and only shows an error state when
/// everything failed.
@MainActor
@Observable
final class SavedQueryStore {
    var views: [SavedQuery] = []
    var error: String?
    var isLoading = false
    var loadedAt: Date?

    /// True when PostHog said there is another page and this screen did not ask
    /// for it.
    ///
    /// **The list endpoint paginates by page number and ignores `?limit=`**, so
    /// there is no "just ask for more" — see `PostHogAPI.savedQueries`. A phone
    /// showing the first page of a large project must say so rather than let the
    /// reader conclude the project has fewer views than it does; that is the
    /// same failure `QueryResponse.isTruncated` exists for on the query path.
    var hasMorePages = false

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<SavedQuery> = try await client.send(
                PostHogAPI.savedQueries(projectID: projectID)
            )
            // Trouble first, then alphabetical — the same ordering rule
            // `WarehouseStore` uses for sources, for the same reason: the screen
            // exists to surface what is broken.
            views = page.results.sorted {
                ($0.materialization.severity, $0.name) < ($1.materialization.severity, $1.name)
            }
            hasMorePages = page.next != nil
            error = nil
            loadedAt = Date()
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Views whose stored table is older than their definition or their last
    /// attempted run. The banner's contents.
    var stale: [SavedQuery] { views.filter(\.isServingStaleData) }
}

/// One view's SQL and its run history.
///
/// Two requests, fetched together and held for the life of the detail screen.
/// They are caught separately on purpose: `data_modeling_jobs` answers **HTTP
/// 400** for a `saved_query_id` its filter does not recognise (see
/// `PostHogAPI.dataModelingJobs`), and losing the run history is not a reason to
/// lose the definition the reader opened the screen for.
@MainActor
@Observable
final class SavedQueryDetailStore {
    var detail: SavedQuery?
    var jobs: [DataModelingJob] = []
    var definitionError: String?
    var historyError: String?
    var isLoading = false

    var latestJob: DataModelingJob? { jobs.first }

    func load(client: PostHogClient, projectID: Int, id: String) async {
        guard detail == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        async let detailResult = warehouseAttempt {
            try await client.send(PostHogAPI.savedQuery(projectID: projectID, id: id))
                as SavedQuery
        }
        async let jobsResult = warehouseAttempt {
            try await client.send(
                PostHogAPI.dataModelingJobs(projectID: projectID, savedQueryID: id)
            ) as Page<DataModelingJob>
        }

        switch await detailResult {
        case .success(let value): detail = value
        case .failure(let error): definitionError = Self.message(for: error)
        }
        switch await jobsResult {
        case .success(let page):
            // The API's ordering is not pinned by its contract, so newest-first
            // is imposed here rather than assumed. A run with no timestamp sorts
            // last rather than being dropped.
            jobs = page.results.sorted {
                ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast)
            }
        case .failure(let error): historyError = Self.message(for: error)
        }
    }

    private static func message(for error: any Error) -> String {
        (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
    }
}

/// Runs an async call and reports its outcome instead of throwing it.
///
/// Two independent requests have to be able to fail independently: `try await`
/// on the first `async let` propagates out of the awaiting scope and takes the
/// second's result with it, so a rejected `saved_query_id` filter would discard
/// the definition that arrived beside it.
///
/// A free function rather than an `async` overload of `Result.init(catching:)` —
/// the stdlib already declares that initialiser on `Result where Failure == any
/// Error` for a *synchronous* closure, and adding a second spelling of the same
/// name is an overload-resolution problem waiting to be inherited by whoever
/// reads this next.
private func warehouseAttempt<T>(
    _ body: () async throws -> T
) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

// MARK: - Tint

/// Tint for a materialisation state. Always paired with the state's own word —
/// `MaterializationState.title` — and never used alone.
///
/// `.editedSinceRun` and `.cancelled` take the warning tint rather than the
/// critical one, and that is not softening: nothing errored, the stored table is
/// simply behind. `.failed` is the only one that gets red.
func materializationTint(_ state: MaterializationState) -> Color {
    switch state {
    case .failed: Theme.Status.critical
    case .editedSinceRun, .cancelled, .neverRun: Theme.accentWarm
    case .running: Theme.accent
    case .upToDate: Theme.Status.good
    case .unscheduled, .notMaterialized: .secondary
    }
}

// MARK: - Banner

/// States, in words, that some view is answering queries with old rows.
///
/// A separate banner from `WarehouseAlertBanner` above it rather than more rows
/// inside that one, because the two say different things and merging them would
/// blur both: a failing *source* means new data is not arriving, and a stale
/// *view* means old data is being served as if it were new. A reader needs to
/// know which they have.
struct WarehouseModelingAlertBanner: View {
    let views: [SavedQuery]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(headline, systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Status.criticalInk)

                // The sentence the screen exists for. Stated once, above the
                // list, rather than left to be inferred from a red pill.
                Text("Queries built on these views are still answering — from rows that predate the problem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(views) { view in
                    Text("\(view.name): \(view.latestError ?? view.materialization.title.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        views.count == 1
            ? "1 view is serving stale data"
            : "\(views.count) views are serving stale data"
    }
}

// MARK: - Row

struct WarehouseViewRowView: View {
    let view: SavedQuery

    var body: some View {
        DataRow(
            // The glyph separates a materialized view from a plain one before
            // the name is read, the way the table row separates an imported
            // table from a query-built one — and for the same reason: only one
            // of the two can go stale.
            glyph: view.materialization.systemImage,
            tint: materializationTint(view.materialization),
            title: view.name,
            subtitle: view.shapeSummary,
            footnote: runLine,
            // The pill carries the state as a word, so the tint above never has
            // to. `.notMaterialized` still gets one: "View" is information, and
            // a row with no pill in a column of rows with pills reads as a row
            // that failed to load its pill.
            accessory: .pill(view.materialization.title, materializationTint(view.materialization))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
    }

    private var runLine: String {
        if let error = view.latestError { return error }
        if let lastRun = view.lastRunAt {
            return "Last run \(lastRun.formatted(.relative(presentation: .named)))"
        }
        return view.isMaterialized ? "Never run" : "Not materialized"
    }

    /// The consequence is spoken, not just the state.
    ///
    /// "Materialisation failed" tells a sighted reader where to look; it does
    /// not tell anyone what it means. The sentence is already written for the
    /// detail screen, so VoiceOver gets it here rather than a shorter version
    /// of the same words.
    private var spokenSummary: String {
        var parts = ["\(view.name), \(view.materialization.title)"]
        parts.append(view.materialization.consequence)
        parts.append(view.shapeSummary)
        if let error = view.latestError {
            parts.append("last error: \(error)")
        } else if let lastRun = view.lastRunAt {
            parts.append("last run \(lastRun.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Detail

struct WarehouseViewDetailView: View {
    /// The list row. Everything except the SQL is already here, so the screen
    /// draws immediately and the fetched detail fills in the definition.
    let view: SavedQuery
    @Environment(AppModel.self) private var model
    @State private var store = SavedQueryDetailStore()

    /// The detail response when it has arrived, otherwise the row.
    ///
    /// The row is not a lesser version of the detail. Compared field by field
    /// against the published contract, `DataWarehouseSavedQuery` adds exactly
    /// six keys over `DataWarehouseSavedQueryMinimal` and drops none:
    /// `query`, `suspended`, `latest_history_id`, and the three write-only ones
    /// (`dag_id`, `edited_history_id`, `soft_update`). Two of those matter here
    /// — the SQL and the suspension list — and everything else on this screen
    /// can be drawn from the row while they are in flight.
    private var current: SavedQuery { store.detail ?? view }

    var body: some View {
        List {
            stateSection
            if current.isSuspended { suspensionSection }
            definitionSection
            if !current.columns.isEmpty { columnsSection }
            historySection
            metadataSection
        }
        .pageSurface()
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let client = model.client, let projectID = model.projectID else { return }
            await store.load(client: client, projectID: projectID, id: view.id)
        }
    }

    // MARK: State

    private var stateSection: some View {
        Section {
            Card(accent: materializationTint(current.materialization)) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        current.materialization.title,
                        systemImage: current.materialization.systemImage
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Status.ink(for: materializationTint(current.materialization)))

                    // The state's consequence, always — not only when it is bad.
                    // "Not materialized. The SQL runs fresh on every query." is
                    // the answer to the same question as the failure copy, and a
                    // screen that only explains itself when something is wrong
                    // teaches nobody what the states mean.
                    Text(current.materialization.consequence)
                        .font(.callout)

                    if let error = current.latestError {
                        Text(error)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.Status.criticalInk)
                            .textSelection(.enabled)
                    }

                    if current.disagreesWith(latestJob: store.latestJob) {
                        // Both numbers come from different endpoints and the app
                        // cannot adjudicate between them, so it reports the
                        // disagreement rather than picking a winner.
                        Text("The view reports \(current.status.title.lowercased()), but its most recent run did not. The run history below is the primary record.")
                            .font(.caption)
                            .foregroundStyle(Theme.Status.warningInk)
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Suspension

    /// The worst state this screen can report, and the only one that is
    /// invisible from the list.
    ///
    /// Given its own section rather than another line in the state card because
    /// it says something the state does not: `.failed` means the last run failed
    /// and the next one may not, and this means there is no next one. The
    /// distinction is the difference between "check back later" and "nobody is
    /// coming".
    private var suspensionSection: some View {
        Section {
            ForEach(current.suspensions) { suspension in
                VStack(alignment: .leading, spacing: 6) {
                    Text(suspension.engine)
                        .font(.subheadline.weight(.semibold))
                    if let at = suspension.at {
                        Text("Suspended \(at.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(suspension.reason)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Status.criticalInk)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            SectionLabel(text: "Materialisation suspended", systemImage: "hand.raised")
        } footer: {
            // PostHog's own words for what suspension does, because the
            // consequence is the point and paraphrasing it loses the "until the
            // query is resumed" half. Resuming is a write, and this client's key
            // is read-only, so the screen says where it can be done rather than
            // offering a button it cannot honour.
            Text("Scheduled runs skip a suspended engine until the view is resumed, so the stored table will not refresh on its own. Resuming is a write — do it in the PostHog console.")
        }
    }

    // MARK: Definition

    @ViewBuilder
    private var definitionSection: some View {
        Section {
            if let sql = current.query {
                // Horizontally scrollable, because SQL is written in lines that
                // mean something and wrapping a `SELECT` list mid-expression
                // makes it harder to read than a scroll does. Monospaced for the
                // same reason the table detail sets names monospaced: alignment
                // is what makes a column list scannable.
                ScrollView(.horizontal) {
                    Text(sql)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }
                .scrollIndicators(.visible)
                .accessibilityLabel("Definition. \(sql)")
            } else if let error = store.definitionError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if store.isLoading {
                Text("Loading the definition…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Reached when the detail arrived without a `query`. Says what is
                // missing rather than drawing an empty code block, which would
                // read as a view with no SQL — something PostHog does not allow.
                Text("PostHog returned no SQL for this view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionLabel(text: "Definition", systemImage: "chevron.left.forwardslash.chevron.right")
        } footer: {
            // The list endpoint genuinely does not carry the SQL, and saying so
            // is cheaper than letting the momentary blank read as a bug.
            Text("The list of views does not include SQL; this was fetched for this view alone.")
        }
    }

    // MARK: Columns

    private var columnsSection: some View {
        Section {
            ForEach(current.columns) { column in
                HStack(alignment: .firstTextBaseline) {
                    Text(column.name)
                        .font(.subheadline.monospaced())
                    Spacer(minLength: 12)
                    Text(column.type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !column.schemaValid {
                        StatusPill(text: "Invalid", tint: Theme.Status.critical)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(column.name), type \(column.type)"
                        + (column.schemaValid ? "" : ", schema invalid")
                )
            }
        } header: {
            SectionLabel(text: "\(current.columns.count) columns", systemImage: "list.bullet")
        }
    }

    // MARK: Run history

    @ViewBuilder
    private var historySection: some View {
        Section {
            if !store.jobs.isEmpty {
                ForEach(store.jobs) { job in
                    JobRowView(job: job)
                }
            } else if let error = store.historyError {
                // The run history failing does not take the definition with it,
                // and the sentence says which half is missing so the screen is
                // not read as half-broken.
                Text("Couldn't load the run history. \(error)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if store.isLoading {
                Text("Loading runs…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if current.isMaterialized {
                Text("No materialisation runs recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Not an empty state: a view that is not materialized has no
                // runs by definition, and "no runs recorded" would imply
                // something is missing.
                Text("This view is not materialized, so it has no runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            SectionLabel(text: "Recent runs", systemImage: "clock.arrow.circlepath")
        }
    }

    // MARK: Metadata

    private var metadataSection: some View {
        Section {
            LabeledContent("Query as") {
                Text(current.name).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Status") { Text(current.status.title) }
            LabeledContent("Refresh") {
                // "Never" and an absent cadence mean the same thing to PostHog
                // and are spelled differently; both say the same words here.
                Text(current.hasRefreshSchedule ? (current.syncFrequency ?? "—") : "Not scheduled")
            }
            if let lastRun = current.lastRunAt {
                LabeledContent("Last run") {
                    Text(lastRun, format: .relative(presentation: .named))
                }
            }
            if let folder = current.folderName {
                LabeledContent("Folder") { Text(folder) }
            }
            if let origin = current.origin, origin != "data_warehouse" {
                LabeledContent("Origin") { Text(origin.replacingOccurrences(of: "_", with: " ")) }
            }
            if let author = current.createdBy {
                LabeledContent("Created by") { Text(author) }
            }
            if let created = current.createdAt {
                LabeledContent("Created") {
                    Text(created, format: .relative(presentation: .named))
                }
            }
            if let description = current.description {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    // Rendered as text and nothing else. PostHog's own contract
                    // marks this field as possibly user- or LLM-supplied and
                    // says to treat it as data, never as instructions.
                    Text(description).font(.callout)
                }
            }
        } header: {
            SectionLabel(text: "View", systemImage: "info.circle")
        }
    }
}

// MARK: - Job row

struct JobRowView: View {
    let job: DataModelingJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.lastRunAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Undated run")
                    .font(.subheadline)
                Spacer(minLength: 12)
                StatusPill(text: job.status.title, tint: tint)
            }
            Text(detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = job.error {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.Status.criticalInk)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var tint: Color {
        switch job.status {
        case .failed: Theme.Status.critical
        case .cancelled: Theme.accentWarm
        case .running: Theme.accent
        case .completed: Theme.Status.good
        case .modified, .unknown: .secondary
        }
    }

    private var detailLine: String {
        var parts = [job.rowSummary]
        if let duration = job.duration {
            parts.append(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds])))
        }
        return parts.joined(separator: " · ")
    }

    private var spoken: String {
        var parts = [
            job.lastRunAt.map { "Run \($0.formatted(.relative(presentation: .named)))" } ?? "Undated run",
            job.status.title,
            job.rowSummary,
        ]
        if let error = job.error { parts.append("error: \(error)") }
        return parts.joined(separator: ", ")
    }
}
