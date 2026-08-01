import Foundation

/// Which of the two panes a question is about.
public enum ReplayCaptureKind: Sendable, Hashable {
    case console
    case network
}

/// Why a pane is empty.
///
/// The distinction that matters is the last two. "Nobody logged anything" and
/// "nobody can tell you whether anything was logged" are different sentences,
/// and printing the first when the second is true is a lie the reader has no
/// way to catch.
public enum ReplayCaptureStatus: Sendable, Hashable {
    /// There are entries. Nothing to explain.
    case captured
    /// The recorder did not load the plugin, or the project switched it off.
    case disabled
    /// The plugin was loaded and captured nothing.
    case enabledButNone
    /// Neither fact is in the data that was fetched.
    case unknown
}

/// What the recorder was configured to capture, as far as the fetched snapshots
/// say.
///
/// Both signals are `type: 5` custom events the PostHog recorder writes into the
/// snapshot stream itself, so reading them costs nothing:
///
/// - **`$session_options`** carries `activePlugins`, the list of rrweb plugins
///   that actually loaded. This is the authoritative one.
/// - **`$remote_config_received`** carries `consoleLogRecordingEnabled` and
///   `networkPayloadCapture`, which is the project's *intent*. Weaker — it says
///   what was asked for, not what ran — so it is only consulted when the
///   startup event was not seen.
///
/// Neither is guaranteed to be there. The recorder emits them once at startup,
/// and a recording that continues an already-running recorder may not include
/// either event. Existing entries therefore remain stronger evidence than an
/// absent configuration signal.
public struct ReplayCaptureConfig: Sendable, Hashable {
    /// True once `$session_options` has been seen, which is what makes
    /// `activePlugins` trustworthy as a negative.
    public var sawStartupEvent = false
    public var activePlugins: Set<String> = []
    /// From `$remote_config_received`. Intent, not outcome.
    public var remoteConsoleEnabled: Bool?
    public var remoteNetworkEnabled: Bool?

    public init() {}

    public var consoleEnabled: Bool? { enabled(.console) }
    public var networkEnabled: Bool? { enabled(.network) }

    private func enabled(_ kind: ReplayCaptureKind) -> Bool? {
        let plugin = switch kind {
        case .console: ReplayConsoleEntry.pluginName
        case .network: ReplayNetworkEntry.pluginName
        }
        if activePlugins.contains(plugin) { return true }
        if sawStartupEvent { return false }
        return switch kind {
        case .console: remoteConsoleEnabled
        case .network: remoteNetworkEnabled
        }
    }

    /// Entries always win: whatever the configuration claimed, data on screen
    /// is the stronger fact.
    public func status(_ kind: ReplayCaptureKind, hasEntries: Bool) -> ReplayCaptureStatus {
        if hasEntries { return .captured }
        return switch enabled(kind) {
        case .some(true): .enabledButNone
        case .some(false): .disabled
        case nil: .unknown
        }
    }

    mutating func absorb(_ other: ReplayCaptureConfig) {
        sawStartupEvent = sawStartupEvent || other.sawStartupEvent
        activePlugins.formUnion(other.activePlugins)
        remoteConsoleEnabled = other.remoteConsoleEnabled ?? remoteConsoleEnabled
        remoteNetworkEnabled = other.remoteNetworkEnabled ?? remoteNetworkEnabled
    }
}

/// Console output and network timing, read out of rrweb events the player has
/// already fetched and decompressed.
///
/// This costs **no additional API request**. `SnapshotParser` hands back every
/// rrweb event in a blob range; the console and network panes are two of those
/// event types that were previously forwarded to the web view and otherwise
/// ignored. The organisation-wide rate limit is untouched by this file.
public struct ReplayDiagnostics: Sendable, Equatable {
    public private(set) var console: [ReplayConsoleEntry] = []
    public private(set) var network: [ReplayNetworkEntry] = []
    public private(set) var capture = ReplayCaptureConfig()

    public init() {}

    public var isEmpty: Bool { console.isEmpty && network.isEmpty }

    public func consoleCount(_ level: ReplayConsoleLevel) -> Int {
        console.count { $0.level == level }
    }

    public var failureCount: Int { network.count(where: \.isFailure) }

    /// Reads one chunk of snapshot events.
    ///
    /// Deliberately `nonisolated` and cheap enough to run inside the same
    /// detached task that parses the JSONL, so a megabyte of rrweb never
    /// touches the main actor twice.
    public static func extract(from events: [SnapshotEvent]) -> ReplayDiagnostics {
        var result = ReplayDiagnostics()

        for event in events {
            switch event.type {
            case 5: result.readCustom(event)
            case 6: result.readPlugin(event)
            default: continue
            }
        }

        result.console.sort { $0.timestamp < $1.timestamp }
        result.network.sort { $0.start < $1.start }
        return result
    }

    /// Folds a later chunk into this one, in place.
    ///
    /// Blobs arrive a range at a time while playback is already running, so both
    /// lists grow rather than being rebuilt. Requests are deduplicated by
    /// identity — a retry that re-reads a range must not double the waterfall —
    /// and console lines are not, because two identical lines logged in the same
    /// millisecond are two lines.
    public mutating func merge(_ other: ReplayDiagnostics) {
        capture.absorb(other.capture)

        var known = Set(network.map(\.id))
        for entry in other.network where known.insert(entry.id).inserted {
            network.append(entry)
        }
        network.sort { $0.start < $1.start }

        var seen = Set(console.map(\.id))
        for entry in other.console {
            console.append(uniquing(entry, against: &seen))
        }
        console.sort { $0.timestamp < $1.timestamp }
    }

    /// Keeps `Identifiable` honest across a chunk boundary without pretending
    /// two identical log lines are one.
    private func uniquing(
        _ entry: ReplayConsoleEntry,
        against seen: inout Set<String>
    ) -> ReplayConsoleEntry {
        var candidate = entry.id
        var suffix = 1
        while !seen.insert(candidate).inserted {
            suffix += 1
            candidate = "\(entry.id)#\(suffix)"
        }
        guard candidate != entry.id else { return entry }
        return ReplayConsoleEntry(
            id: candidate,
            level: entry.level,
            rawLevel: entry.rawLevel,
            parts: entry.parts,
            trace: entry.trace,
            timestamp: entry.timestamp
        )
    }

    // MARK: - Readers

    /// `type: 6` — an rrweb plugin event.
    private mutating func readPlugin(_ event: SnapshotEvent) {
        guard let data = event.event["data"],
              let plugin = data["plugin"]?.stringValue,
              let payload = data["payload"]
        else { return }

        switch plugin {
        case ReplayConsoleEntry.pluginName:
            let id = "c\(Int(event.timestamp))-\(console.count)"
            if let entry = ReplayConsoleEntry.make(
                payload: payload, timestampMS: event.timestamp, id: id
            ) {
                console.append(entry)
            }

        case ReplayNetworkEntry.pluginName:
            guard case .array(let requests)? = payload["requests"] else { return }
            for request in requests {
                // Identity is the request itself, not its position: the same
                // buffered entry can be re-sent in a later batch.
                guard let url = request["name"]?.stringValue else { continue }
                let offset = request["startTime"]?.doubleValue ?? 0
                let origin = request["timeOrigin"]?.doubleValue ?? 0
                let id = "n\(Int(origin))-\(Int(offset * 1000))-\(url)"
                if let entry = ReplayNetworkEntry.make(entry: request, id: id) {
                    network.append(entry)
                }
            }

        default:
            // rrweb supports third-party plugins and PostHog has added its own
            // before. An unknown one is not an error.
            break
        }
    }

    /// `type: 5` — a PostHog custom event in the snapshot stream.
    private mutating func readCustom(_ event: SnapshotEvent) {
        guard let data = event.event["data"],
              let tag = data["tag"]?.stringValue,
              let payload = data["payload"]
        else { return }

        switch tag {
        case "$session_options":
            capture.sawStartupEvent = true
            if case .array(let plugins)? = payload["activePlugins"] {
                capture.activePlugins.formUnion(plugins.compactMap(\.stringValue))
            }

        case "$remote_config_received":
            if let enabled = payload["consoleLogRecordingEnabled"] {
                capture.remoteConsoleEnabled = Self.truth(enabled)
            }
            if let payloadCapture = payload["networkPayloadCapture"] {
                capture.remoteNetworkEnabled = Self.networkTiming(payloadCapture)
            }

        default:
            break
        }
    }

    /// `networkPayloadCapture.capturePerformance` is an object in current SDKs
    /// and a bare boolean in older ones. Both are accepted; `false` for the
    /// whole `networkPayloadCapture` key means off.
    private static func networkTiming(_ value: JSONValue) -> Bool? {
        if case .bool(let flag) = value { return flag }
        guard let performance = value["capturePerformance"] else { return nil }
        if case .bool(let flag) = performance { return flag }
        if let timing = performance["network_timing"] { return truth(timing) }
        // An object with no `network_timing` key is still capture switched on.
        if case .object = performance { return true }
        return nil
    }

    /// A flag is a flag. A string `"true"` would be somebody else's convention,
    /// and guessing at one is how a setting silently reads as its opposite.
    private static func truth(_ value: JSONValue) -> Bool? {
        if case .bool(let flag) = value { return flag }
        return nil
    }
}
