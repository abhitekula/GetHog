import Foundation

/// One request the recorded page made.
///
/// Assembled from a `rrweb/network@1` plugin event. Three different producers
/// write into that array and they do not agree on which fields exist — see
/// `make(entry:id:)` — so almost everything here is Optional on purpose: a
/// missing size is *unknown*, not zero.
public struct ReplayNetworkEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let url: String
    /// Only the fetch/XHR wrapper reports this. A stylesheet or image fetched by
    /// the browser has no method in the timing entry.
    public let method: String?
    public let status: Int?
    /// `PerformanceResourceTiming.initiatorType`: `fetch`, `xmlhttprequest`,
    /// `script`, `link`, `img`, `navigation`, …
    public let initiator: String?
    public let contentType: String?
    /// Wall clock, rebased through the page's `timeOrigin`.
    public let start: Date
    public let duration: TimeInterval
    /// Time to first byte, when the timing API reported it. Always ≤ `duration`.
    public let waiting: TimeInterval?
    /// Bytes over the wire, including headers. `0` on a cache hit, which is a
    /// real measurement and not the same as absent.
    public let transferSize: Int?
    public let encodedBodySize: Int?
    public let decodedBodySize: Int?
    /// A performance entry that was already in the browser's buffer when the
    /// recorder started, so it describes something that happened *before* the
    /// replay's first frame.
    public let isInitial: Bool

    public init(
        id: String,
        url: String,
        method: String?,
        status: Int?,
        initiator: String?,
        contentType: String?,
        start: Date,
        duration: TimeInterval,
        waiting: TimeInterval?,
        transferSize: Int?,
        encodedBodySize: Int?,
        decodedBodySize: Int?,
        isInitial: Bool
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.status = status
        self.initiator = initiator
        self.contentType = contentType
        self.start = start
        self.duration = duration
        self.waiting = waiting
        self.transferSize = transferSize
        self.encodedBodySize = encodedBodySize
        self.decodedBodySize = decodedBodySize
        self.isInitial = isInitial
    }

    public var end: Date { start.addingTimeInterval(duration) }

    /// Seconds from the instant the replay is measured from. Negative for
    /// requests the browser buffered before recording began.
    public func offset(from origin: Date) -> TimeInterval {
        start.timeIntervalSince(origin)
    }

    /// A status nobody wants to see. A request whose status was never reported
    /// is not called a failure — that would flag every cached stylesheet.
    public var isFailure: Bool { (status ?? 0) >= 400 }

    /// Bytes to show in a list. Prefers what actually crossed the network;
    /// falls back to the compressed body when the wire size was not reported.
    public var wireSize: Int? {
        if let transferSize, transferSize > 0 { return transferSize }
        if let encodedBodySize, encodedBodySize > 0 { return encodedBodySize }
        return transferSize ?? encodedBodySize
    }

    /// Served without touching the network. Distinguishable only when the entry
    /// came from the timing API, which is why it is `false` rather than `nil`
    /// for a wrapper-only entry.
    public var isCached: Bool {
        transferSize == 0 && (decodedBodySize ?? 0) > 0
    }

    public var host: String? {
        URL(string: url)?.host()
    }

    /// The part of a URL worth putting in a narrow row.
    ///
    /// Path only. The query string used to be appended, and on a phone that made
    /// eight consecutive calls to the same endpoint render as eight identical
    /// middle-truncated strings — the differing part was in the elided middle.
    /// Measured on a rendered card. The whole URL is one tap away.
    public var pathLabel: String {
        guard let components = URLComponents(string: url) else { return url }
        return components.path.isEmpty ? "/" : components.path
    }
}

// MARK: - Parsing

extension ReplayNetworkEntry {

    /// rrweb's network plugin name, exercised by deterministic replay fixtures.
    static let pluginName = "rrweb/network@1"

    /// Builds an entry from one element of `data.payload.requests`.
    ///
    /// Returns `nil` for anything that is not a request. Two things in that
    /// array are not:
    ///
    /// - **`entryType: "serverTiming"`.** PostHog flattens a resource's
    ///   `serverTiming` sub-entries into the same array as its parent. They
    ///   carry a bare token for a name — such as a server-timing metric — rather
    ///   than a fetched URL. Rendered, they would be waterfall rows for things
    ///   that were never fetched.
    /// - **A name that is not a URL.** Belt and braces for the same class of
    ///   entry, and cheap.
    ///
    /// The producer shapes supported by the replay payload:
    ///
    /// | | `entryType` | `method` | status field | sizes |
    /// |---|---|---|---|---|
    /// | resource timing | `resource` | — | `responseStatus` | yes |
    /// | navigation timing | `navigation` | — | `responseStatus` | yes |
    /// | fetch/XHR wrapper | *absent* | yes | `status` | no |
    /// | merged XHR | `resource` | yes | both | yes |
    ///
    /// `status` is preferred because the wrapper is the only producer that has
    /// it; resource and navigation entries fall back to `responseStatus`.
    static func make(entry: JSONValue, id: String) -> ReplayNetworkEntry? {
        guard entry["entryType"]?.stringValue != "serverTiming" else { return nil }
        guard let url = entry["name"]?.stringValue, url.contains("://") else { return nil }

        let timeOrigin = entry["timeOrigin"]?.doubleValue
        let startTime = entry["startTime"]?.doubleValue
        // `startTime`/`endTime` are milliseconds since the page's `timeOrigin`,
        // so a row cannot be placed on the session timeline without adding the
        // two. `timestamp` is the same instant already summed, rounded to a
        // whole millisecond, and is the fallback when either half is missing.
        let startMS: Double
        if let timeOrigin, let startTime, timeOrigin.isFinite, startTime.isFinite {
            startMS = timeOrigin + startTime
        } else if let stamp = entry["timestamp"]?.doubleValue, stamp.isFinite {
            startMS = stamp
        } else {
            return nil
        }

        return ReplayNetworkEntry(
            id: id,
            url: url,
            method: entry["method"]?.stringValue,
            status: code(entry["status"]) ?? code(entry["responseStatus"]),
            initiator: nonEmpty(entry["initiatorType"]?.stringValue),
            contentType: nonEmpty(entry["contentType"]?.stringValue),
            start: Date(timeIntervalSince1970: startMS / 1000),
            duration: duration(entry) / 1000,
            waiting: waiting(entry).map { $0 / 1000 },
            transferSize: size(entry["transferSize"]),
            encodedBodySize: size(entry["encodedBodySize"]),
            decodedBodySize: size(entry["decodedBodySize"]),
            isInitial: entry["isInitial"] == .bool(true)
        )
    }

    /// Milliseconds the request took.
    ///
    /// `duration` is preferred, but an in-progress navigation entry can report
    /// `0` for it even when `endTime` is already later —
    /// `PerformanceNavigationTiming.duration` is measured to `loadEventEnd`,
    /// which is still zero while the page is loading. Trusting that zero would
    /// draw a non-instantaneous document request as instantaneous.
    private static func duration(_ entry: JSONValue) -> Double {
        if let reported = entry["duration"]?.doubleValue, reported.isFinite, reported > 0 {
            return reported
        }
        if let start = entry["startTime"]?.doubleValue,
           let end = entry["endTime"]?.doubleValue,
           start.isFinite, end.isFinite, end > start {
            return end - start
        }
        return 0
    }

    /// Milliseconds spent waiting for the first byte, when the timing API
    /// reported both ends. Absent for wrapper-only entries.
    private static func waiting(_ entry: JSONValue) -> Double? {
        guard let requestStart = entry["requestStart"]?.doubleValue,
              let responseStart = entry["responseStart"]?.doubleValue,
              requestStart > 0, responseStart > requestStart
        else { return nil }
        return responseStart - requestStart
    }

    /// `0` means "not reported" for a status code, which is what a cross-origin
    /// timing entry gives when it is not allowed to say.
    private static func code(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.isFinite, number > 0 else { return nil }
        return Int(number)
    }

    private static func size(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0,
              number < 9e15
        else { return nil }
        return Int(number)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
