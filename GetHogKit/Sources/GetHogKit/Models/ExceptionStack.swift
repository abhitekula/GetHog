import Foundation

/// The `$exception_list` property of a `$exception` event: the exception that
/// was thrown, plus the chain of causes behind it.
///
/// The public exception interface permits a resolved source frame to retain the
/// raw SDK frame that preceded symbolication. This small synthetic example shows
/// the relationship without carrying any tenant event data:
///
/// ```json
/// [{"id":"018f2000-0000-7000-8000-000000000001",
///   "mechanism":{"handled":true,"synthetic":false,"type":"generic"},
///   "stacktrace":{"type":"resolved","frames":[
///     {"column":8,"in_app":true,"lang":"javascript","line":24,
///      "mangled_name":"a","resolved":true,"resolved_name":"loadExample",
///      "source":"webpack://example/src/client.ts","synthetic":false,
///      "junk_drawer":{"raw_frame":{"colno":320,
///        "filename":"https://cdn.example.com/static/app.js",
///        "function":"a","in_app":true,"lineno":1,"synthetic":false}}}]},
///   "type":"Error",
///   "value":"Synthetic request failed."}]
/// ```
///
/// Two things in that payload drive most of the design here.
///
/// **The resolved frame and the raw frame are different frames.** `line`/`column`
/// are positions in the *original source*; `junk_drawer.raw_frame.lineno`/`colno`
/// are positions in the shipped bundle — 24:8 against 1:320 in the example.
/// Reading one pair against the other filename would put a reader
/// at a position that does not exist. `StackFrame` therefore never mixes them:
/// `location` is whichever pair matches the file it is printed beside.
///
/// **Resolution fails per frame, not per stack.** A stack may be labelled
/// resolved while individual frames carry `"resolved": false` and a
/// `resolve_failure` string. The frame-level field therefore decides what the UI
/// may present as source.
public struct ExceptionChain: Sendable, Hashable {

    /// As PostHog stores it: **innermost cause first, thrown exception last**.
    ///
    /// Chained exceptions contain multiple items. This model follows the
    /// exception-interface ordering of oldest cause first and thrown exception
    /// last.
    ///
    /// `thrown` and `causes` exist so that if it is ever found to be backwards,
    /// one property changes rather than every call site.
    public let exceptions: [ExceptionEntry]

    public init(exceptions: [ExceptionEntry]) {
        self.exceptions = exceptions
    }

    /// The exception that actually reached the handler — the last entry.
    public var thrown: ExceptionEntry? { exceptions.last }

    /// What caused it, outermost cause first, so the chain reads
    /// "X … caused by Y … caused by Z" the way a Java or Python traceback prints.
    public var causes: [ExceptionEntry] {
        exceptions.dropLast().reversed()
    }

    public var isChained: Bool { exceptions.count > 1 }

    /// Every entry in reading order: thrown first, then each cause.
    public var orderedForDisplay: [ExceptionEntry] {
        guard let thrown else { return [] }
        return [thrown] + causes
    }

    /// Decodes the array as it arrives from a HogQL cell, where
    /// `properties.$exception_list` comes back as a **JSON string**, not as
    /// nested JSON. Also accepts an already-parsed array, because the REST
    /// issue-event shape nests it directly.
    public static func decode(from value: JSONValue?) -> ExceptionChain? {
        guard let value, !value.isNull else { return nil }

        let data: Data?
        if let text = value.stringValue {
            data = text.data(using: .utf8)
        } else {
            data = try? JSONEncoder().encode(value)
        }
        guard let data else { return nil }
        return decode(from: data)
    }

    public static func decode(from data: Data) -> ExceptionChain? {
        guard let entries = try? JSONDecoder().decode([ExceptionEntry].self, from: data),
              !entries.isEmpty
        else { return nil }
        return ExceptionChain(exceptions: entries)
    }
}

public struct ExceptionEntry: Sendable, Decodable, Hashable, Identifiable {
    /// PostHog's per-exception uuid. Absent on some SDKs, so `id` falls back to
    /// the type and message, which is enough to keep a `ForEach` stable.
    public let rawID: String?
    /// The class name — `ReferenceError`, `APIError`, `CustomEvent`.
    public let type: String
    /// The message. Named `value` in the payload.
    public let value: String?
    public let module: String?
    public let mechanism: ExceptionMechanism?
    public let stack: StackTrace?

    public var id: String { rawID ?? "\(type)|\(value ?? "")" }

    enum CodingKeys: String, CodingKey {
        case id, type, value, module, mechanism
        case stacktrace
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try? c.decodeIfPresent(String.self, forKey: .id)
        // Falls back rather than throwing: an entry with a message and no class
        // is still worth printing, and dropping the whole chain over it is not.
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "Exception"
        value = try? c.decodeIfPresent(String.self, forKey: .value)
        module = try? c.decodeIfPresent(String.self, forKey: .module)
        mechanism = try? c.decodeIfPresent(ExceptionMechanism.self, forKey: .mechanism)
        stack = try? c.decodeIfPresent(StackTrace.self, forKey: .stacktrace)
    }

    public init(
        rawID: String? = nil,
        type: String,
        value: String? = nil,
        module: String? = nil,
        mechanism: ExceptionMechanism? = nil,
        stack: StackTrace? = nil
    ) {
        self.rawID = rawID
        self.type = type
        self.value = value
        self.module = module
        self.mechanism = mechanism
        self.stack = stack
    }

    public var frames: [StackFrame] { stack?.frames ?? [] }
}

public struct ExceptionMechanism: Sendable, Decodable, Hashable {
    /// `generic`, `onerror`, `onunhandledrejection`, `chained`, …
    public let type: String?
    /// Whether the app caught it. `false` means it reached the top of the stack.
    public let handled: Bool?
    /// Whether the SDK manufactured the stack rather than reading a real one.
    public let synthetic: Bool?
    /// For a chained exception, the attribute it hung off — `cause`, `__cause__`.
    public let source: String?

    enum CodingKeys: String, CodingKey { case type, handled, synthetic, source }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        handled = try? c.decodeIfPresent(Bool.self, forKey: .handled)
        synthetic = try? c.decodeIfPresent(Bool.self, forKey: .synthetic)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
    }

    public init(
        type: String? = nil,
        handled: Bool? = nil,
        synthetic: Bool? = nil,
        source: String? = nil
    ) {
        self.type = type
        self.handled = handled
        self.synthetic = synthetic
        self.source = source
    }
}

public struct StackTrace: Sendable, Decodable, Hashable {

    /// What PostHog says it did with the stack.
    ///
    /// Advisory only — see `StackFrame.isResolved` for the fact that matters.
    public enum Kind: String, Sendable, Hashable {
        /// Symbolication ran. Individual frames may still have failed.
        case resolved
        /// Frames are as the SDK sent them.
        case raw
        case unknown
    }

    public let kind: Kind
    /// **Callee first**: the frame the exception was raised in leads the array.
    /// This is the ordering defined by the exception interface.
    public let frames: [StackFrame]

    enum CodingKeys: String, CodingKey { case type, frames }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try? c.decodeIfPresent(String.self, forKey: .type)
        kind = raw.flatMap(Kind.init(rawValue:)) ?? .unknown
        frames = (try? c.decodeIfPresent([StackFrame].self, forKey: .frames)) ?? []
    }

    public init(kind: Kind, frames: [StackFrame]) {
        self.kind = kind
        self.frames = frames
    }

    /// Frames the user's own code owns, in the order the stack lists them.
    public var inAppFrames: [StackFrame] { frames.filter(\.isInApp) }

    /// How many frames symbolication actually produced source for.
    public var resolvedCount: Int { frames.count(where: \.isResolved) }
}

/// One line of a stack trace, carrying both the resolved and the raw view of the
/// same call site — and never merging them.
public struct StackFrame: Sendable, Decodable, Hashable, Identifiable {

    /// PostHog's stable id for the frame (`raw_id`), which is what the
    /// symbolication cache is keyed on. Synthesised when absent so `ForEach`
    /// still has something to hold; two identical frames in a recursive stack
    /// would otherwise collide.
    public let rawID: String?

    /// Whether symbolication produced source for *this* frame.
    ///
    /// The field that decides whether the app is allowed to print something
    /// that looks like source; the stack-level type is not enough.
    public let isResolved: Bool

    /// Why PostHog could not resolve this frame, when supplied.
    public let resolveFailure: String?

    /// The demangled function name, present only when `isResolved`.
    public let resolvedName: String?
    /// The name as shipped — `M`, `?`, `applyUpdate`.
    public let mangledName: String?

    /// The **original** source path, e.g. `webpack://_N_E/../../src/…/foo.ts`.
    /// Present on unresolved frames too, where it is the bundle path instead —
    /// which is why it is only ever printed alongside the matching line/column.
    public let source: String?
    /// Position in `source`. Original-source coordinates when resolved.
    public let line: Int?
    public let column: Int?

    public let isInApp: Bool
    /// `javascript`, `python`, `node`, …
    public let lang: String?
    /// The SDK manufactured this frame; there was no real one.
    public let isSynthetic: Bool
    /// PostHog's own hint that the frame looks like a symbolication artefact.
    public let isSuspicious: Bool

    /// The frame exactly as the SDK sent it, before any source map was applied.
    public let raw: RawStackFrame?

    public var id: String {
        rawID ?? "\(source ?? "?"):\(line ?? -1):\(column ?? -1):\(mangledName ?? "?")"
    }

    enum CodingKeys: String, CodingKey {
        case lang, line, column, source, resolved, synthetic, suspicious
        case inApp = "in_app"
        case rawID = "raw_id"
        case resolvedName = "resolved_name"
        case mangledName = "mangled_name"
        case resolveFailure = "resolve_failure"
        case junkDrawer = "junk_drawer"
    }

    private enum JunkDrawerKeys: String, CodingKey { case rawFrame = "raw_frame" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rawID = try? c.decodeIfPresent(String.self, forKey: .rawID)
        isResolved = (try? c.decodeIfPresent(Bool.self, forKey: .resolved)) ?? false
        resolveFailure = try? c.decodeIfPresent(String.self, forKey: .resolveFailure)
        resolvedName = try? c.decodeIfPresent(String.self, forKey: .resolvedName)
        mangledName = try? c.decodeIfPresent(String.self, forKey: .mangledName)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        line = try? c.decodeIfPresent(Int.self, forKey: .line)
        column = try? c.decodeIfPresent(Int.self, forKey: .column)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        isSynthetic = (try? c.decodeIfPresent(Bool.self, forKey: .synthetic)) ?? false
        isSuspicious = (try? c.decodeIfPresent(Bool.self, forKey: .suspicious)) ?? false

        // `junk_drawer` is PostHog's escape hatch for anything the resolver did
        // not model. The raw frame is the only key GetHog reads out of it,
        // and it is the whole reason an unresolved frame can still be reported
        // honestly rather than as a blank.
        let junk = try? c.nestedContainer(keyedBy: JunkDrawerKeys.self, forKey: .junkDrawer)
        raw = try? junk?.decodeIfPresent(RawStackFrame.self, forKey: .rawFrame) ?? nil
        let declaredInApp = try? c.decodeIfPresent(Bool.self, forKey: .inApp)
        isInApp = declaredInApp ?? raw?.isInApp ?? false
    }

    public init(
        rawID: String? = nil,
        isResolved: Bool,
        resolveFailure: String? = nil,
        resolvedName: String? = nil,
        mangledName: String? = nil,
        source: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        isInApp: Bool = false,
        lang: String? = nil,
        isSynthetic: Bool = false,
        isSuspicious: Bool = false,
        raw: RawStackFrame? = nil
    ) {
        self.rawID = rawID
        self.isResolved = isResolved
        self.resolveFailure = resolveFailure
        self.resolvedName = resolvedName
        self.mangledName = mangledName
        self.source = source
        self.line = line
        self.column = column
        self.isInApp = isInApp
        self.lang = lang
        self.isSynthetic = isSynthetic
        self.isSuspicious = isSuspicious
        self.raw = raw
    }

    // MARK: - Presentation

    /// The best name available, preferring the demangled one.
    ///
    /// `?` is what a JS SDK emits for an anonymous function and it survives into
    /// `mangled_name` verbatim; printing it as-is would read as a defect in the
    /// app, so it is spelled out.
    public var functionName: String {
        if isResolved, let resolvedName, !resolvedName.isEmpty { return resolvedName }
        for candidate in [mangledName, raw?.function] {
            guard let candidate, !candidate.isEmpty else { continue }
            return candidate == "?" ? "(anonymous)" : candidate
        }
        return "(anonymous)"
    }

    /// The file this frame should be *printed against*, paired with
    /// `location` below. Resolved frames get the original source path; anything
    /// else gets the file the SDK actually reported.
    public var fileDescription: String? {
        let path = isResolved ? (source ?? raw?.filename) : (raw?.filename ?? source)
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    /// The trailing component of `fileDescription`, for the one-line form.
    ///
    /// URLs get their query and fragment dropped first: a bundle URL carrying
    /// `?v=1712…` would otherwise print the cache-buster as if it were the
    /// filename.
    public var fileName: String? {
        guard let path = fileDescription else { return nil }
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let component = withoutQuery.split(separator: "/").last.map(String.init)
        return (component?.isEmpty == false) ? component : withoutQuery
    }

    /// `line:column` in whichever coordinate space `fileDescription` is in.
    ///
    /// The pairing is the point. A resolved frame may use one coordinate pair
    /// while its raw bundle frame uses another; printing the
    /// bundle's column beside the source's filename would be a fabricated
    /// position.
    public var location: (line: Int, column: Int?)? {
        if isResolved {
            if let line { return (line, column) }
            if let rawLine = raw?.line { return (rawLine, raw?.column) }
            return nil
        }
        if let rawLine = raw?.line { return (rawLine, raw?.column) }
        if let line { return (line, column) }
        return nil
    }

    /// `foo.ts:173:10`, or just the file when there is no position.
    public var locationDescription: String? {
        guard let fileName else { return nil }
        guard let location else { return fileName }
        guard let column = location.column else { return "\(fileName):\(location.line)" }
        return "\(fileName):\(location.line):\(column)"
    }

    /// Whether this frame is a bundled/minified position the app must not dress
    /// up as source.
    ///
    /// An unresolved frame with a *demangled-looking* name is still unresolved:
    /// a readable function name does not prove its coordinates were resolved.
    public var isMinified: Bool { !isResolved }
}

/// The frame as the SDK sent it, before symbolication.
///
/// Lives under `junk_drawer.raw_frame` in the payload. Kept whole because it is
/// the only honest thing to show for a frame that failed to resolve.
public struct RawStackFrame: Sendable, Decodable, Hashable {
    public let filename: String?
    public let function: String?
    public let line: Int?
    public let column: Int?
    public let isInApp: Bool?
    /// The build the bundle came from, when PostHog matched one. Absent on
    /// frames from a development server and may be present on built bundles.
    public let chunkID: String?

    enum CodingKeys: String, CodingKey {
        case filename, function
        case line = "lineno"
        case column = "colno"
        case isInApp = "in_app"
        case chunkID = "chunk_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filename = try? c.decodeIfPresent(String.self, forKey: .filename)
        function = try? c.decodeIfPresent(String.self, forKey: .function)
        line = try? c.decodeIfPresent(Int.self, forKey: .line)
        column = try? c.decodeIfPresent(Int.self, forKey: .column)
        isInApp = try? c.decodeIfPresent(Bool.self, forKey: .isInApp)
        chunkID = try? c.decodeIfPresent(String.self, forKey: .chunkID)
    }

    public init(
        filename: String? = nil,
        function: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        isInApp: Bool? = nil,
        chunkID: String? = nil
    ) {
        self.filename = filename
        self.function = function
        self.line = line
        self.column = column
        self.isInApp = isInApp
        self.chunkID = chunkID
    }
}

/// One entry of `$exception_steps` — PostHog's breadcrumbs.
///
/// Documented as *"Breadcrumb-style steps recorded via `addExceptionStep` before
/// the exception, each with a `$message`, `$timestamp`, and any custom
/// properties"*.
///
/// This is modelled from the documented shape and rendered only when it is
/// present. An absent steps array does not create an empty card.
public struct ExceptionStep: Sendable, Hashable, Identifiable {
    public let id: Int
    public let message: String?
    public let timestamp: Date?
    /// Whatever else the caller attached. Kept whole because `addExceptionStep`
    /// takes arbitrary properties and dropping them would discard the part the
    /// author chose to record.
    public let properties: [String: JSONValue]

    public init(id: Int, message: String?, timestamp: Date?, properties: [String: JSONValue]) {
        self.id = id
        self.message = message
        self.timestamp = timestamp
        self.properties = properties
    }

    /// The custom properties, without the two PostHog defines.
    public var customProperties: [(key: String, value: JSONValue)] {
        properties
            .filter { $0.key != "$message" && $0.key != "$timestamp" }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }
    }

    /// Accepts either a nested array or the JSON **string** a HogQL cell hands
    /// back, the same two shapes `$exception_list` arrives in.
    static func decodeList(from value: JSONValue?) -> [ExceptionStep] {
        guard let value, !value.isNull else { return [] }

        let parsed: JSONValue?
        if let text = value.stringValue {
            parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } else {
            parsed = value
        }
        guard case .array(let elements)? = parsed else { return [] }

        return elements.enumerated().compactMap { index, element in
            guard case .object(let object) = element else { return nil }
            return ExceptionStep(
                id: index,
                message: object["$message"]?.stringValue,
                timestamp: object["$timestamp"]?.stringValue.flatMap(PostHogDate.parse),
                properties: object
            )
        }
    }
}

/// One `$exception` occurrence, with its chain.
///
/// This is what the detail screen loads: the newest event belonging to an issue.
public struct ExceptionOccurrence: Sendable, Hashable, Identifiable {
    public let id: String
    public let timestamp: Date?
    /// `error`, `warning`, `info` — `$exception_level`.
    public let level: String?
    /// `$exception_fingerprint` — what PostHog grouped this event by. Useful when
    /// asking why two issues that look identical are separate.
    public let fingerprint: String?
    public let chain: ExceptionChain
    public let steps: [ExceptionStep]

    public init(
        id: String,
        timestamp: Date?,
        level: String?,
        fingerprint: String? = nil,
        chain: ExceptionChain,
        steps: [ExceptionStep] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.fingerprint = fingerprint
        self.chain = chain
        self.steps = steps
    }

    /// Reads the row shape `PostHogAPI.errorIssueOccurrence` asks for.
    ///
    /// Returns `nil` rather than an empty occurrence when the list is missing:
    /// "this event carried no `$exception_list`" and "this issue has no stack"
    /// are the same outcome for the reader, and both must show the honest
    /// fallback rather than an empty trace card.
    public static func from(row: QueryRow) -> ExceptionOccurrence? {
        guard let chain = ExceptionChain.decode(from: row.value("exception_list")) else {
            return nil
        }
        return ExceptionOccurrence(
            id: row.string("uuid") ?? UUID().uuidString,
            timestamp: row.date("timestamp"),
            level: row.string("level"),
            fingerprint: row.string("fingerprint"),
            chain: chain,
            steps: ExceptionStep.decodeList(from: row.value("steps"))
        )
    }

    public static func first(in response: QueryResponse) -> ExceptionOccurrence? {
        response.rows.lazy.compactMap(ExceptionOccurrence.from(row:)).first
    }
}
