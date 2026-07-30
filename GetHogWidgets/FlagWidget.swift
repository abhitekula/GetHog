import AppIntents
import GetHogKit
import SwiftUI
import WidgetKit

// MARK: - Configuration

/// A feature flag offered to the widget's edit sheet.
///
/// The candidate list is *only* the flags whose `quickToggleAllowed` the app
/// recorded as true. That opt-in is the user's explicit decision, made in the
/// app next to the flag's description and rollout, and it is the only thing that
/// exposes a flag to a surface with no confirmation dialog. Revoking it in the
/// app empties this list on the next sync and any configured widget falls back
/// to its no-data state — which is the correct outcome, not a bug.
struct WidgetFlagEntity: AppEntity {

    let id: Int
    let key: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Feature Flag" }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(key)") }

    static var defaultQuery: WidgetFlagQuery { WidgetFlagQuery() }

    init(id: Int, key: String) {
        self.id = id
        self.key = key
    }

    init(_ flag: SharedSnapshot.Flag) {
        id = flag.id
        key = flag.key
    }
}

struct WidgetFlagQuery: EntityQuery {

    func entities(for identifiers: [Int]) async throws -> [WidgetFlagEntity] {
        let allowed = WidgetCache.quickToggleFlags()
        return identifiers.compactMap { id in
            allowed.first { $0.id == id }.map(WidgetFlagEntity.init)
        }
    }

    func suggestedEntities() async throws -> [WidgetFlagEntity] {
        WidgetCache.quickToggleFlags().map(WidgetFlagEntity.init)
    }

    func defaultResult() async -> WidgetFlagEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectFlagIntent: WidgetConfigurationIntent {

    static var title: LocalizedStringResource { "Select Feature Flag" }
    static var description: IntentDescription {
        IntentDescription("Choose a flag you have allowed to be toggled from outside the app.")
    }

    @Parameter(title: "Feature Flag")
    var flag: WidgetFlagEntity?

    init() {}

    init(flag: WidgetFlagEntity?) {
        self.flag = flag
    }
}

// MARK: - The toggle itself

/// Records the *request* to flip a flag and opens the app; it does not perform
/// the write.
///
/// Three reasons, in order of weight. The write needs the API key from the
/// keychain and the org-wide rate-limit governor, neither of which belongs in an
/// extension. It may need the user's biometric confirmation, and a widget
/// process is not a place to run an authentication prompt. And when it fails —
/// a 403 from a key without flag-write scope is the common case — there is
/// nowhere in a widget to say so, so a silent failure would leave the user
/// believing a live flag had changed when it had not.
///
/// Conforms to `SetValueIntent` so the same intent drives both the interactive
/// `Toggle` in the widget and the Control Center toggle.
struct ToggleFlagFromWidgetIntent: AppIntent, SetValueIntent {

    static var title: LocalizedStringResource { "Toggle Feature Flag" }
    static var description: IntentDescription {
        IntentDescription("Asks GetHog to enable or disable a feature flag. The app performs the change.")
    }

    /// The hand-off. Everything above depends on this being true.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Feature Flag")
    var flag: WidgetFlagEntity?

    @Parameter(title: "Enabled")
    var value: Bool

    init() {
        value = false
    }

    init(flag: WidgetFlagEntity?, value: Bool) {
        self.flag = flag
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        guard let flag else { return .result() }
        // Re-check the opt-in at perform time. A configuration saved days ago
        // must not survive the user revoking permission in the app.
        guard WidgetCache.quickToggleFlag(id: flag.id) != nil else { return .result() }

        WidgetCache.store.requestFlagWrite(
            PendingFlagWrite(flagID: flag.id, key: flag.key, desiredActive: value, requestedAt: Date())
        )
        return .result()
    }
}

// MARK: - Timeline

/// Deliberately without a `relevance`, unlike the metric and health entries.
///
/// Both of those score themselves for the Smart Stack out of something that
/// changes: a verdict that turns critical, a number that crosses a line the user
/// drew. A flag has neither. `active` is a steady state, not an event — a flag
/// that has been on for three weeks is exactly as newsworthy today as it was
/// yesterday — and the snapshot carries no history to say when it last changed.
///
/// Everything that looked like a signal here was checked and rejected. A
/// `PendingFlagWrite` awaiting the app is real, but `AppModel.consumePendingIntentWork`
/// clears it on the very next foreground, and the toggle that writes it opens the
/// app immediately — so the window it exists in is too short for a widget timeline
/// to observe, and a score built on it would fire approximately never while
/// reading as though it did something. Staleness is real too, and points the wrong
/// way: promoting a card *because* its data is old is an argument for showing the
/// user something less trustworthy, not more.
///
/// So this entry claims nothing, which leaves `TimelineEntry.relevance` at its
/// `nil` default. That is a stronger statement than a score of zero and a much
/// stronger one than a constant: a constant relevance is a widget telling the
/// system it matters without ever saying when, which is the one thing this API
/// cannot be used for honestly.
struct FlagEntry: TimelineEntry {
    let date: Date
    let flag: SharedSnapshot.Flag?
    let capturedAt: Date?
    /// True when the snapshot exists but holds no opted-in flags — a different
    /// problem from "never synced", and it needs different words.
    let noneAllowed: Bool

    var freshness: WidgetFreshness { WidgetFreshness(capturedAt: capturedAt, now: date) }

    static func sample(at date: Date = Date()) -> FlagEntry {
        FlagEntry(date: date, flag: WidgetCache.sample.flags.first, capturedAt: date, noneAllowed: false)
    }
}

struct FlagProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> FlagEntry { .sample() }

    func snapshot(for configuration: SelectFlagIntent, in context: Context) async -> FlagEntry {
        context.isPreview ? .sample() : entry(for: configuration, at: Date())
    }

    func timeline(for configuration: SelectFlagIntent, in context: Context) async -> Timeline<FlagEntry> {
        WidgetRefresh.timeline(from: Date()) { date in
            entry(for: configuration, at: date)
        }
    }

    private func entry(for configuration: SelectFlagIntent, at date: Date) -> FlagEntry {
        let snapshot = WidgetCache.snapshot()
        let allowed = snapshot?.quickToggleFlags ?? []
        let match = configuration.flag.flatMap { chosen in allowed.first { $0.id == chosen.id } } ?? allowed.first
        return FlagEntry(
            date: date,
            flag: match,
            capturedAt: snapshot?.capturedAt,
            noneAllowed: snapshot != nil && allowed.isEmpty
        )
    }
}

// MARK: - Widget

struct FlagWidget: Widget {

    static let kind = "app.gethog.widget.flag"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectFlagIntent.self, provider: FlagProvider()) { entry in
            FlagWidgetView(entry: entry)
                .containerBackground(Theme.cardBackground, for: .widget)
        }
        .configurationDisplayName("Feature Flag")
        .description("Shows a flag's state and asks GetHog to change it. Only flags you allow quick toggling for appear here.")
        // Home Screen only: an interactive toggle on a Lock Screen accessory
        // would draw a control the user cannot press.
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FlagWidgetView: View {

    let entry: FlagEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if let flag = entry.flag {
            content(for: flag)
        } else if entry.noneAllowed {
            NoDataView(message: "No flags allowed for quick toggle. Turn one on in GetHog.")
        } else {
            NoDataView()
        }
    }

    private func content(for flag: SharedSnapshot.Flag) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "flag.pattern.checkered")
                    .imageScale(.small)
                Text(flag.key)
                    .font(.caption)
                    .lineLimit(family == .systemSmall ? 2 : 1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)

            // State in words and in a symbol, never in the fill colour alone.
            HStack(spacing: 4) {
                Image(systemName: flag.active ? "checkmark.circle.fill" : "circle.slash")
                    .imageScale(.small)
                Text(flag.active ? "Enabled" : "Disabled")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(stateStyle(for: flag))

            Spacer(minLength: 0)

            Toggle(isOn: flag.active, intent: ToggleFlagFromWidgetIntent(flag: WidgetFlagEntity(flag), value: !flag.active)) {
                Text(flag.active ? "Turn off in app" : "Turn on in app")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .toggleStyle(.switch)
            // Says out loud what the tap actually does. Presenting this as an
            // instant flip would be a lie: the app opens and performs the write.
            .accessibilityLabel(WidgetAccessibility.label(for: flag))
            .accessibilityHint("Opens GetHog to \(flag.active ? "disable" : "enable") this flag")

            FreshnessFooter(freshness: entry.freshness, showsRefresh: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stateStyle(for flag: SharedSnapshot.Flag) -> AnyShapeStyle {
        guard renderingMode == .fullColor else { return AnyShapeStyle(.primary) }
        return AnyShapeStyle(flag.active ? WidgetPalette.positive : WidgetPalette.neutral)
    }
}

#Preview("Flag small", as: .systemSmall) {
    FlagWidget()
} timeline: {
    FlagEntry.sample()
    FlagEntry(date: Date(), flag: nil, capturedAt: Date(), noneAllowed: true)
    FlagEntry(date: Date(), flag: nil, capturedAt: nil, noneAllowed: false)
}
