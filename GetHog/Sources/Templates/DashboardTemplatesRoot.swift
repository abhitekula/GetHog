import GetHogKit
import SwiftUI

// MARK: - Store

@MainActor
@Observable
final class DashboardTemplatesStore {
    private(set) var templates: [DashboardTemplate] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedAt: Date?

    var search = ""

    func load(client: PostHogClient, projectID: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page: Page<DashboardTemplate> = try await client.send(
                PostHogAPI.dashboardTemplates(projectID: projectID)
            )
            templates = page.results.sorted(by: DashboardTemplate.featuredFirst)
            loadedAt = Date()
            error = nil
        } catch {
            self.error = (error as? PostHogError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Narrows what is already loaded. The whole library is 26 rows and arrives
    /// in one request, so there is nothing a server-side search would add except
    /// a request per keystroke against an organisation-wide budget.
    var visible: [DashboardTemplate] {
        guard !search.isEmpty else { return templates }
        return templates.filter {
            $0.templateName.localizedCaseInsensitiveContains(search)
                || ($0.summary ?? "").localizedCaseInsensitiveContains(search)
                || $0.insightKinds.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
}

// MARK: - Root

/// PostHog's dashboard template library, as a gallery.
///
/// A gallery rather than a table because the data is: 26 templates, most with
/// real artwork on `posthog.com`, and a name-plus-description list of them is
/// something nobody would scroll on a phone. The picture is what makes a
/// template recognisable before its description has been read.
///
/// **Read-only, by decision.** Applying one is
/// `POST .../dashboards/create_from_template_json/` and needs `dashboard:write`,
/// which this app does not ask for — the reasoning is written out in full on
/// `PostHogAPI.dashboardTemplates`. The short version: a template creates 4–47
/// insights in a production project, this app cannot delete any of them, and
/// most of them are parameterised so applying with the defaults quietly builds
/// the wrong dashboard.
struct DashboardTemplatesRoot: View {
    @Environment(AppModel.self) private var model
    @State private var store = DashboardTemplatesStore()

    var body: some View {
        @Bindable var store = store

        content
            .navigationTitle("Templates")
            .navigationDestination(for: DashboardTemplate.self) { template in
                DashboardTemplateDetailView(template: template)
            }
            .toolbar { ProjectSwitcher() }
            .projectSubtitle()
            .searchable(text: $store.search, prompt: "Search templates")
            .refreshable { await load() }
            .task(id: model.projectID) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.error, store.templates.isEmpty {
            EmptyStateView(
                title: "Couldn't load templates",
                systemImage: "exclamationmark.triangle",
                message: error,
                actionTitle: "Try again",
                action: { Task { await load() } }
            )
        } else if store.visible.isEmpty && !store.isLoading {
            emptyState
        } else {
            PageScaffold {
                LazyVGrid(columns: columns, spacing: Theme.Space.l) {
                    ForEach(store.visible) { template in
                        NavigationLink(value: template) {
                            TemplateCard(template: template)
                        }
                        .buttonStyle(.plain)
                        // Pairs the row's two cards to the taller of them. The
                        // card absorbs the slack with a trailing `Spacer`, so the
                        // extra height goes below the text rather than stretching
                        // the artwork.
                        .frame(maxHeight: .infinity)
                    }
                }

                if let loadedAt = store.loadedAt {
                    FreshnessLabel(date: loadedAt)
                }
            }
            .skeleton(store.isLoading && store.templates.isEmpty)
        }
    }

    /// One column on a phone, two where there is room. Adaptive rather than
    /// fixed: a card whose artwork has been squeezed below about 260pt stops
    /// being recognisable, which is the only reason the artwork is there.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 260), spacing: Theme.Space.l, alignment: .top)]
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.search.isEmpty {
            EmptyStateView(
                title: "No matching templates",
                systemImage: "magnifyingglass",
                message: "No template name, description or insight type matches “\(store.search)”."
            )
        } else {
            EmptyStateView(
                title: "No templates available",
                systemImage: "rectangle.on.rectangle.angled",
                message: "Templates are ready-made dashboards — a set of insights, "
                    + "already laid out, for a topic like product analytics or retention. "
                    + "PostHog ships a library of them and teams can save their own. "
                    + "This project can see none right now.",
                actionTitle: "Reload",
                action: { Task { await load() } }
            )
        }
    }

    private func load() async {
        guard let client = model.client, let projectID = model.projectID else { return }
        await store.load(client: client, projectID: projectID)
    }
}

// MARK: - Card

private struct TemplateCard: View {
    let template: DashboardTemplate

    /// Read because the card changes shape rather than shrinking at accessibility
    /// sizes; see `titleRow`.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TemplateArtwork(template: template)

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    titleRow

                    if let summary = template.summary {
                        Text(summary)
                            .font(Theme.Typography.body)
                            // `.secondary` measured 3.44:1 against this white
                            // card, under the 4.5:1 AA floor for text this size.
                            .foregroundStyle(Theme.Ink.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(contents)
                        .font(Theme.Typography.caption)
                        // Measured 1.72:1 light and 2.31:1 dark on `.tertiary`.
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.l)

                // Lets the card take the row's height instead of its own.
                // Measured on iPad: paired cards differed by about 30pt purely
                // because one description wrapped to three lines and the other to
                // two, so a grid of identical objects looked ragged.
                Spacer(minLength: 0)
            }
        }
        // A template name is a product noun — "Landing Pages Report" — not prose.
        // Measured at AX5: the hyphenation dictionary set it as `Land-` / `ing
        // Pa…`, and an invented hyphen is indistinguishable from one that was
        // always in the name. `zxx` means "no linguistic content", so no
        // dictionary applies.
        .typesettingLanguage(Locale.Language(identifier: "zxx"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    /// Title and badge side by side, stacked at accessibility sizes.
    ///
    /// The pill holds its width whatever the type size, so beside it the title —
    /// the only thing telling one template from another — was left about six
    /// characters at AX5 and then clipped at two lines, in a card with most of a
    /// screen of unused height beneath it.
    @ViewBuilder
    private var titleRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                titleText
                featuredPill
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                titleText
                Spacer(minLength: 0)
                featuredPill
            }
        }
    }

    private var titleText: some View {
        Text(template.templateName)
            .font(Theme.Typography.title)
            // Uncapped at accessibility sizes: two lines of type that large is
            // half a name, and the cap is there to keep a grid of cards an even
            // height, which the `Spacer` above now does properly.
            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var featuredPill: some View {
        if template.isFeatured {
            // A word, not a star alone: "featured" is a state, and this app never
            // encodes one in colour or in a glyph by itself.
            StatusPill(text: "Featured", tint: Theme.accentWarm)
        }
    }

    /// What this template builds, in the line a card has room for.
    private var contents: String {
        var parts: [String] = []
        if let count = template.tileCount {
            parts.append("\(count) insight\(count == 1 ? "" : "s")")
        }
        if !template.insightKinds.isEmpty {
            parts.append(template.insightKinds.joined(separator: " · "))
        }
        // Never "0 insights" when the endpoint simply did not serialise them —
        // that would understate a template that builds twenty.
        return parts.isEmpty ? "Contents not listed" : parts.joined(separator: " — ")
    }

    private var spoken: String {
        var text = template.templateName
        if template.isFeatured { text += ", featured" }
        if let summary = template.summary { text += ". \(summary)" }
        text += ". \(contents)."
        return text
    }
}

/// The template's own artwork, with an honest stand-in when there is none.
private struct TemplateArtwork: View {
    let template: DashboardTemplate

    var body: some View {
        ZStack {
            // A tinted band rather than a grey box: it reads as a deliberate
            // cover when the image is absent or still arriving, instead of as a
            // picture that failed.
            Theme.accent.opacity(0.10)

            if let url = template.imageURL {
                // These come from `posthog.com`'s static art directory, not from
                // the API, so they are not billed against the organisation's
                // rate-limit budget. `AsyncImage` caches them in the shared
                // URL cache, so a scroll back up costs nothing.
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholderGlyph
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    private var placeholderGlyph: some View {
        Image(systemName: "square.grid.2x2")
            .font(.largeTitle)
            .foregroundStyle(Theme.accent.opacity(0.5))
    }
}

// MARK: - Detail

/// What a template contains, and what it would ask for.
///
/// The variables section is the part that justifies the screen. A template's
/// tiles are parameterised — `"series": ["{DAILY_ACTIVE_USER}"]` is a
/// placeholder, not an event — so "apply this" is a short interview, and seeing
/// the questions is what tells a reader whether the template fits their product
/// before they open a laptop to build it.
struct DashboardTemplateDetailView: View {
    let template: DashboardTemplate

    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold {
            if let summary = template.summary {
                Text(summary)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            tiles
            variables
            applyNote
        }
        .navigationTitle(template.templateName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ProjectSwitcher() }
        .projectSubtitle()
    }

    @ViewBuilder
    private var tiles: some View {
        SectionLabel(text: "Insights", systemImage: "square.grid.2x2")

        if let tiles = template.tiles, !tiles.isEmpty {
            VStack(spacing: Theme.Space.xs) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    Card {
                        DataRow(
                            glyph: glyph(for: tile.kindTitle),
                            title: tile.name,
                            subtitle: tile.summary,
                            footnote: tile.kindTitle,
                            subtitleLineLimit: 3,
                            accessory: .none
                        )
                    }
                }
            }
        } else {
            // Absence, not zero: the list response does not always serialise
            // tiles, and claiming "no insights" for a template that builds
            // twenty would be a lie the reader cannot check.
            SectionEmptyState(
                text: "PostHog didn't return this template's tile list, so what it builds can't be shown here.",
                systemImage: "square.grid.2x2"
            )
        }
    }

    @ViewBuilder
    private var variables: some View {
        if let variables = template.variables, !variables.isEmpty {
            SectionLabel(text: "You'd be asked for", systemImage: "questionmark.circle")

            VStack(spacing: Theme.Space.xs) {
                ForEach(variables) { variable in
                    Card {
                        DataRow(
                            glyph: "bolt",
                            tint: Theme.accentWarm,
                            title: variable.name,
                            subtitle: variable.summary,
                            footnote: variable.isRequired ? "Required" : "Optional",
                            subtitleLineLimit: 3,
                            accessory: .none
                        )
                    }
                }
            }
        }
    }

    /// States plainly that this app will not apply the template, and where to.
    ///
    /// Written as a fact rather than as a disabled button: a greyed-out "Apply"
    /// invites a tap that can never succeed, and the honest version of a feature
    /// this app has declined to build is a sentence, not a dead control.
    private var applyNote: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                CardHeader(
                    title: "Applying this builds a dashboard",
                    systemImage: "square.and.arrow.down",
                    subtitle: template.isParameterised
                        ? "It asks for \(template.variables?.count ?? 0) answers first"
                        : nil
                )

                Text(
                    "GetHog reads your project; it doesn't create dashboards. "
                        + "That needs a `dashboard:write` key, and a dashboard this app "
                        + "made couldn't be deleted from here again."
                )
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let url = model.webURL(path: "dashboard") {
                    Link(destination: url) {
                        Label("Open dashboards in PostHog", systemImage: "arrow.up.forward.square")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
    }

    /// The tile's own kind, as a shape — so a wall of tiles is scannable before
    /// any of their names have been read.
    private func glyph(for kind: String) -> String {
        switch kind {
        case "Trends": "chart.xyaxis.line"
        case "Funnels": "line.3.horizontal.decrease"
        case "Retention": "square.grid.3x3"
        case "Lifecycle": "person.badge.clock"
        case "Paths": "point.3.connected.trianglepath.dotted"
        case "Stickiness": "calendar.badge.clock"
        case "Data table": "tablecells"
        case "Text": "text.alignleft"
        default: "chart.bar"
        }
    }
}
