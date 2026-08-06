import Foundation
import Testing

@testable import GetHogKit

@Suite("Shared snapshot")
struct SharedSnapshotTests {

    /// Each test gets its own directory so a leftover file from one can never
    /// make another pass.
    private func makeStore() throws -> (SharedSnapshotStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (SharedSnapshotStore(directory: dir), dir)
    }

    private func sample(capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> SharedSnapshot {
        SharedSnapshot(
            projectID: 1_001,
            projectName: "Default project",
            metrics: [
                .init(
                    id: "42",
                    title: "Weekly active users",
                    value: 1234,
                    unit: nil,
                    previous: 1000,
                    sparkline: [900, 950, 1000, 1100, 1234],
                    dashboardID: 7
                ),
                .init(id: "43", title: "Bounce rate", value: 41.2, unit: "%", previous: nil,
                      sparkline: [], dashboardID: nil),
            ],
            flags: [
                .init(id: 1, key: "new-onboarding", active: true, quickToggleAllowed: true),
                .init(id: 2, key: "risky-migration", active: false, quickToggleAllowed: false),
            ],
            capturedAt: capturedAt
        )
    }

    @Test("round-trips every field the widgets read")
    func roundTrip() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let written = sample()
        try store.write(written)
        let read = try #require(try store.read())

        #expect(read.projectID == written.projectID)
        #expect(read.projectName == written.projectName)
        #expect(read.metrics.map(\.id) == ["42", "43"])
        #expect(read.metrics[0].value == 1234)
        #expect(read.metrics[0].previous == 1000)
        #expect(read.metrics[0].sparkline == [900, 950, 1000, 1100, 1234])
        // `nil` must survive as `nil`, not collapse to a default: a missing
        // previous value means "no delta known", which the widget renders
        // differently from a flat delta.
        #expect(read.metrics[1].previous == nil)
        #expect(read.metrics[1].unit == "%")
        #expect(read.metrics[1].sparkline.isEmpty)
        #expect(read.flags.map(\.key) == ["new-onboarding", "risky-migration"])
        #expect(read.flags[0].quickToggleAllowed)
        #expect(read.flags[1].quickToggleAllowed == false)
        // Sub-second drift would make "Updated 0s ago" flicker between reads.
        #expect(abs(read.capturedAt.timeIntervalSince(written.capturedAt)) < 0.001)
    }

    @Test("a second write replaces the first rather than appending")
    func writeReplaces() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.write(sample())
        let later = SharedSnapshot(
            projectID: 1,
            projectName: "Other",
            metrics: [],
            flags: [],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try store.write(later)

        let read = try #require(try store.read())
        #expect(read.projectID == 1)
        #expect(read.metrics.isEmpty)
    }

    @Test("a missing file reads as nil, not as an error")
    func missingFile() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A widget installed before the app has ever synced hits this path on
        // every timeline reload; it must be an ordinary "no data yet" answer.
        #expect(try store.read() == nil)
        #expect(store.loadOrNil() == nil)
    }

    @Test("a corrupt file reads as nil so a bad write can't wedge the widget")
    func corruptFile() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{ not json".utf8).write(to: store.fileURL)

        #expect(throws: (any Error).self) { try store.read() }
        #expect(store.loadOrNil() == nil)
    }

    @Test("staleness is the age of the capture")
    func staleness() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = sample(capturedAt: captured)

        #expect(snapshot.staleness(now: captured.addingTimeInterval(600)) == 600)
        #expect(snapshot.isStale(now: captured.addingTimeInterval(600)) == false)
        #expect(snapshot.isStale(now: captured.addingTimeInterval(3600)))
        #expect(snapshot.isStale(now: captured.addingTimeInterval(120), tolerance: 60))
    }

    @Test("a capture stamped in the future reads as fresh, not as negative age")
    func futureCaptureClamps() {
        // Clocks drift and snapshots survive time-zone/NTP corrections. A
        // negative age would format as "Updated in 5 minutes".
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = sample(capturedAt: captured)

        #expect(snapshot.staleness(now: captured.addingTimeInterval(-300)) == 0)
        #expect(snapshot.isStale(now: captured.addingTimeInterval(-300)) == false)
    }

    @Test("metric deltas are computed only when a previous value exists")
    func deltas() throws {
        let snapshot = sample()

        let up = snapshot.metrics[0]
        #expect(up.delta == 234)
        #expect(try #require(up.deltaFraction) == 0.234)

        #expect(up.direction == .up)

        // No previous value: no arrow, no percentage, no invented zero.
        let unknown = snapshot.metrics[1]
        #expect(unknown.delta == nil)
        #expect(unknown.deltaFraction == nil)
        #expect(unknown.direction == .unknown)
    }

    @Test("a previous value of zero yields a delta but no percentage")
    func zeroBaseline() {
        let metric = SharedSnapshot.Metric(
            id: "9", title: "Signups", value: 5, unit: nil, previous: 0, sparkline: [],
            dashboardID: nil
        )
        #expect(metric.delta == 5)
        // Dividing by zero would render "∞%".
        #expect(metric.deltaFraction == nil)
        #expect(metric.direction == .up)
    }

    @Test("carries the dashboard a metric was read from, so a widget tap lands on it")
    func dashboardID() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.write(sample())
        let read = try #require(try store.read())
        #expect(read.metric(id: "42")?.dashboardID == 7)
        // An insight can live on a dashboard the widget was never told about,
        // and the tile the metric came from is the only honest answer. `nil`
        // means "unknown", and must route to the dashboards home rather than
        // to a guess.
        #expect(read.metric(id: "43")?.dashboardID == nil)
    }

    @Test("a snapshot written before dashboards were recorded still decodes")
    func dashboardIDIsBackwardsCompatible() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The App Group file outlives the app that wrote it: after an update,
        // the first read is of the *previous* build's snapshot. If a new field
        // were required, that read would throw and every widget would blank
        // until the next successful refresh — for a field that is advisory.
        //
        // Written to disk and read back through the store rather than decoded
        // with a local `JSONDecoder`, because the store's decoder is
        // `.iso8601`; a hand-rolled one would pass while the shipping path
        // failed.
        let old = """
            {"projectID":1,"projectName":"P","flags":[],\
            "capturedAt":"2026-01-20T00:00:00Z",\
            "metrics":[{"id":"42","title":"WAU","value":5,"sparkline":[]}]}
            """
        try Data(old.utf8).write(to: store.fileURL)

        let decoded = try #require(try store.read())
        #expect(decoded.metrics.count == 1)
        #expect(decoded.metrics[0].dashboardID == nil)
    }

    @Test("lookup by id is available to the widget configuration query")
    func lookup() {
        let snapshot = sample()
        #expect(snapshot.metric(id: "43")?.title == "Bounce rate")
        #expect(snapshot.metric(id: "nope") == nil)
        #expect(snapshot.flag(id: 1)?.key == "new-onboarding")
        // Only opted-in flags may reach Control Center or an interactive widget.
        #expect(snapshot.quickToggleFlags.map(\.id) == [1])
    }

    @Test("falls back to a usable directory when the App Group is unavailable")
    func appGroupFallback() throws {
        // Previews and unsigned builds get nil back from the container lookup;
        // the store must still be constructible and writable rather than
        // trapping, so the widget can reach its no-data state.
        let store = SharedSnapshotStore.resolve(appGroupIdentifier: "group.absent") { _ in nil }
        defer { try? FileManager.default.removeItem(at: store.directory) }

        #expect(store.isSharedContainer == false)
        #expect(store.fileURL.lastPathComponent == "snapshot.json")
        #expect(store.pendingFlagURL.lastPathComponent == "pending-flag.json")

        try store.write(sample())
        #expect(try store.read()?.projectID == 1_001)
    }

    @Test("the identifier wears the team prefix only where the platform demands it")
    func platformAwareAppGroupIdentifier() {
        // The base identifier is what iOS declares, and what every platform
        // degrades to when no prefix is injected.
        #expect(SharedSnapshotStore.appGroupIdentifier == "group.app.gethog")
        #expect(SharedSnapshotStore.appGroupIdentifier(teamIDPrefix: nil)
            == SharedSnapshotStore.appGroupIdentifier)

        // Both branches of the rule, pinned regardless of which platform runs
        // this test. "EXAMPLETEAM" is one character longer than a real signing
        // prefix on purpose, so the privacy scanner never needs to exempt it.
        #expect(SharedSnapshotStore.resolvedAppGroupIdentifier(
            teamIDPrefix: "EXAMPLETEAM.", requiresTeamIDPrefix: true
        ) == "EXAMPLETEAM.group.app.gethog")
        // A raw Team ID arrives without `$(AppIdentifierPrefix)`'s trailing
        // dot; the spelling must come out identical.
        #expect(SharedSnapshotStore.resolvedAppGroupIdentifier(
            teamIDPrefix: "EXAMPLETEAM", requiresTeamIDPrefix: true
        ) == "EXAMPLETEAM.group.app.gethog")
        #expect(SharedSnapshotStore.resolvedAppGroupIdentifier(
            teamIDPrefix: "EXAMPLETEAM.", requiresTeamIDPrefix: false
        ) == "group.app.gethog")
        // An empty prefix degrades to the shared spelling instead of minting
        // the invalid ".group.app.gethog".
        #expect(SharedSnapshotStore.resolvedAppGroupIdentifier(
            teamIDPrefix: "", requiresTeamIDPrefix: true
        ) == "group.app.gethog")

        // And the platform this run is actually on picks the right branch.
        #if os(macOS)
        #expect(SharedSnapshotStore.platformRequiresTeamIDPrefix)
        #expect(SharedSnapshotStore.appGroupIdentifier(teamIDPrefix: "EXAMPLETEAM.")
            == "EXAMPLETEAM.group.app.gethog")
        #else
        #expect(SharedSnapshotStore.platformRequiresTeamIDPrefix == false)
        #expect(SharedSnapshotStore.appGroupIdentifier(teamIDPrefix: "EXAMPLETEAM.")
            == "group.app.gethog")
        #endif
    }

    @Test("every Info.plist spelling of the team prefix has a pinned meaning")
    func teamIDPrefixFromInfoValue() {
        // Absent: every iOS bundle, on purpose, and any build made before the
        // key existed. This is also what the kit's own test host publishes,
        // which is why the rest of this suite sees the unprefixed spelling.
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: nil) == nil)
        // Empty: what `$(TeamIdentifierPrefix)` substitutes to when there is
        // no team — an unsigned local build, which is what a fresh clone makes.
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: "") == nil)
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: "   ") == nil)
        // Unsubstituted: the literal macro, which is what arrives if Info.plist
        // build-setting expansion is ever switched off. Pasted into an
        // identifier it would name a container the *other* process never looks
        // in — creatable, plausible, and silent, which is the precise failure
        // this whole mechanism exists to prevent.
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: "$(TeamIdentifierPrefix)") == nil)
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: "${TeamIdentifierPrefix}") == nil)
        // Not a string at all — a plist edited into a number or an array.
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: 42) == nil)
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: ["EXAMPLETEAM."]) == nil)
        // Substituted: what a signed build publishes, trailing dot and all.
        // "EXAMPLETEAM" is one character longer than a real signing prefix on
        // purpose, so the privacy scanner never needs to exempt it.
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: "EXAMPLETEAM.") == "EXAMPLETEAM.")
        #expect(SharedSnapshotStore.teamIDPrefix(fromInfoValue: " EXAMPLETEAM. ") == "EXAMPLETEAM.")
    }

    @Test("the plist value and the platform together decide one container name")
    func appGroupIdentifierFromInfoValue() {
        // Composition is the whole point: whatever the plist says, the
        // identifier must come out as something a container lookup can use.
        func resolved(_ infoValue: Any?, requiresTeamIDPrefix: Bool) -> String {
            SharedSnapshotStore.resolvedAppGroupIdentifier(
                teamIDPrefix: SharedSnapshotStore.teamIDPrefix(fromInfoValue: infoValue),
                requiresTeamIDPrefix: requiresTeamIDPrefix
            )
        }

        // macOS, signed: the one spelling the sandbox accepts, and the exact
        // string `$(TeamIdentifierPrefix)group.app.gethog` substitutes to in
        // the Release entitlement — so the two can never disagree.
        #expect(resolved("EXAMPLETEAM.", requiresTeamIDPrefix: true) == "EXAMPLETEAM.group.app.gethog")
        // macOS, teamless or unexpanded: the unprefixed spelling, which the
        // Debug entitlements do not grant, so the usability probe sends both
        // processes to their private fallbacks — today's honest empty state.
        for absent: Any? in [nil, "", "$(TeamIdentifierPrefix)"] {
            #expect(resolved(absent, requiresTeamIDPrefix: true) == "group.app.gethog")
        }
        // iOS ignores the prefix outright, so no plist edit anywhere can move
        // a shipping widget's container.
        for value: Any? in [nil, "", "$(TeamIdentifierPrefix)", "EXAMPLETEAM."] {
            #expect(resolved(value, requiresTeamIDPrefix: false) == "group.app.gethog")
        }
    }

    @Test("a bundle that publishes no prefix resolves exactly today's identifier")
    func bundleWithoutPrefixIsUnchanged() {
        // The test host publishes no `GetHogTeamIDPrefix`, which is the same
        // state every iOS bundle is in. Both accessors must therefore land on
        // the identifier the kit shipped before the key existed — on either
        // platform, since the prefix is what is missing rather than the
        // platform rule.
        #expect(SharedSnapshotStore.teamIDPrefix(from: .main) == nil)
        #expect(SharedSnapshotStore.bundleAppGroupIdentifier == "group.app.gethog")
    }

    @Test("the key the kit reads is the key both Mac bundles publish")
    func macBundlesPublishTheTeamPrefixKey() throws {
        // The mechanism is a name agreed between Swift and two plists, and
        // nothing at compile time checks the agreement. A rename on one side
        // costs the Release build its shared container, silently, which is
        // exactly the bug this task fixes — so the agreement is a test.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plists = [
            "GetHogMac/Support/GetHogMac-Info.plist",
            "GetHogMacWidgets/Support/GetHogMacWidgets-Info.plist",
        ]
        for path in plists {
            let data = try Data(contentsOf: repositoryRoot.appending(path: path))
            let plist = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            // The macro, not a literal: a committed Team ID is the one thing
            // this repository must never contain.
            #expect(
                plist[SharedSnapshotStore.teamIDPrefixInfoKey] as? String == "$(TeamIdentifierPrefix)",
                "\(path) must publish the team-prefix key"
            )
        }

        // And the iOS bundles must not publish it: iOS App Group identifiers
        // are unprefixed, and a key here would only invite someone to "fix"
        // the platform rule by editing a plist.
        for path in ["GetHog/Support/GetHog-Info.plist", "GetHog/Support/GetHogWidgets-Info.plist"] {
            let data = try Data(contentsOf: repositoryRoot.appending(path: path))
            let plist = try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
            #expect(plist.keys.contains(SharedSnapshotStore.teamIDPrefixInfoKey) == false, "\(path)")
        }
    }

    @Test("uses the App Group container when one is available")
    func appGroupContainer() throws {
        #expect(SharedSnapshotStore.appGroupIdentifier == "group.app.gethog")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-\(UUID().uuidString)", isDirectory: true)
        // Resolution now creates the container it trusts, so this test owns a
        // real directory and has to clean up after itself.
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SharedSnapshotStore.resolve(appGroupIdentifier: "group.app.gethog") { _ in dir }

        #expect(store.isSharedContainer)
        #expect(store.directory == dir)
    }

    @Test("a container path that cannot be created is not trusted")
    func unusableContainerFallsBack() throws {
        // macOS answers the container lookup with a path even when the App
        // Group entitlement is absent — measured on macOS Debug, where the
        // entitlement is deliberately left out — and the sandbox then denies
        // creating the directory. Simulated portably by parking the container
        // inside a *file*, where creation must fail on every platform.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-directory-\(UUID().uuidString)")
        try Data().write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }

        let store = SharedSnapshotStore.resolve(appGroupIdentifier: "group.app.gethog") { _ in
            parent.appendingPathComponent("group.app.gethog", isDirectory: true)
        }

        // The documented fallback, exactly as if the lookup had answered nil:
        // an honest "not shared" beats a directory every write bounces off.
        #expect(store.isSharedContainer == false)
        #expect(store.directory.lastPathComponent == "GetHogShared")
    }

    @Test("the usability probe's verdict decides shared-container status")
    func probeVerdictDecides() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let trusted = SharedSnapshotStore.resolve(
            appGroupIdentifier: "group.app.gethog",
            container: { _ in dir },
            probe: { _ in true }
        )
        #expect(trusted.isSharedContainer)
        #expect(trusted.directory == dir)

        let refused = SharedSnapshotStore.resolve(
            appGroupIdentifier: "group.app.gethog",
            container: { _ in dir },
            probe: { _ in false }
        )
        #expect(refused.isSharedContainer == false)
        #expect(refused.directory != dir)
    }

    @Test("a creatable container is created, then trusted")
    func creatableContainerIsCreatedAndTrusted() throws {
        // The entitled case: the directory may not exist yet, and resolution
        // itself must make it usable rather than deferring to the first write.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("group-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SharedSnapshotStore.resolve(appGroupIdentifier: "group.app.gethog") { _ in dir }

        #expect(store.isSharedContainer)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("a pending flag write survives the hand-off to the app and is consumed once")
    func pendingFlagWrite() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(store.pendingFlagWrite() == nil)

        let request = PendingFlagWrite(
            flagID: 1, key: "new-onboarding", desiredActive: false,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.enqueue(request)

        let read = try #require(store.pendingFlagWrite())
        #expect(read.flagID == 1)
        #expect(read.desiredActive == false)

        // The app consumes it; a relaunch must not re-apply a flag write.
        store.clearPendingFlagWrite()
        #expect(store.pendingFlagWrite() == nil)
    }

    @Test("a requested destination is separate from a requested flag write")
    func pendingOpen() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.enqueue(PendingFlagWrite(flagID: 7, key: "k", desiredActive: true))
        try store.enqueue(PendingOpen(metricID: "42"))

        // Two different records in two different files: consuming one must not
        // discard the other.
        #expect(store.pendingOpen()?.metricID == "42")
        store.clearPendingOpen()
        #expect(store.pendingOpen() == nil)
        #expect(store.pendingFlagWrite()?.flagID == 7)
    }
}
