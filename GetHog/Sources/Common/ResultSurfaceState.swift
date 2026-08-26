import Foundation
import GetHogKit

/// The complete security namespace in which a read response may publish.
/// Numeric project ids can repeat between hosts, and a replacement credential
/// invalidates work even when both host and project number stay unchanged.
struct ResourceRequestAuthority: Hashable, Sendable {
    let projectID: Int
    let region: PostHogRegion
    let authSessionID: UUID
}

/// Whether the most recent successful request produced rows.
///
/// This is deliberately smaller than a screen's model. The state boundary only
/// needs to know whether a successful result was empty or populated; the rows
/// themselves remain owned by the feature store.
enum ResultContent: Equatable, Sendable {
    case empty
    case populated
}

/// The last response that completed successfully.
///
/// Keeping content and completion time together prevents a view from stamping
/// a failed or still-running request with an unrelated date.
struct ResultSuccess: Equatable, Sendable {
    let content: ResultContent
    let updatedAt: Date
    let scope: ResultScope?

    init(content: ResultContent, updatedAt: Date, scope: ResultScope? = nil) {
        self.content = content
        self.updatedAt = updatedAt
        self.scope = scope
    }
}

/// Identity of the request a successful result answers. Components are opaque
/// but stable (project, window, category, etc.), so unrelated scopes can never
/// borrow each other's rows or completion time after a failure.
struct ResultScope: Equatable, Sendable {
    let components: [String]

    init(_ components: [String]) {
        self.components = components
    }
}

/// Per-invocation publication authority for the simple result stores.
/// Scope rejects another project/account; the generation also rejects an older
/// overlapping request for the same scope, which scope equality alone cannot.
struct ResultRequestAuthority {
    struct Token: Equatable, Sendable {
        let scope: ResultScope
        fileprivate let generation: UInt64
    }

    private(set) var currentScope: ResultScope?
    private var generation: UInt64 = 0
    private(set) var isLoading = false

    mutating func begin(scope: ResultScope) -> Token {
        generation &+= 1
        currentScope = scope
        isLoading = true
        return Token(scope: scope, generation: generation)
    }

    mutating func invalidate() {
        generation &+= 1
        currentScope = nil
        isLoading = false
    }

    func owns(_ token: Token) -> Bool {
        currentScope == token.scope && generation == token.generation
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard owns(token) else { return false }
        isLoading = false
        return true
    }
}

extension ResultScope {
    static func request(
        authority: ResourceRequestAuthority,
        dimensions: [String] = []
    ) -> Self {
        ResultScope([
            "host:\(authority.region.host.absoluteString)",
            "project:\(authority.projectID)",
            "auth:\(authority.authSessionID.uuidString)",
        ] + dimensions)
    }
}

/// The complete presentation state of one independently loaded result.
///
/// Loading and failure are resolved against the last successful response. That
/// distinguishes a first load from refreshing last-good content, and a failed
/// first load from stale content that remains useful after a failed refresh.
enum ResultSurfaceState: Equatable {
    case loading
    case failed(LoadFailure)
    case empty(updatedAt: Date)
    case populated(updatedAt: Date)
    case refreshing(ResultSuccess)
    case stale(ResultSuccess, failure: LoadFailure)

    static func resolve(
        lastSuccess: ResultSuccess?,
        currentScope: ResultScope? = nil,
        isLoading: Bool,
        failure: LoadFailure?
    ) -> Self {
        let scopedSuccess: ResultSuccess? = lastSuccess.flatMap { success -> ResultSuccess? in
            guard success.scope == currentScope else { return nil }
            return success
        }
        if isLoading {
            return scopedSuccess.map(Self.refreshing) ?? .loading
        }
        if let failure {
            return scopedSuccess.map {
                ResultSurfaceState.stale($0, failure: failure)
            } ?? .failed(failure)
        }
        guard let lastSuccess = scopedSuccess else { return .loading }
        switch lastSuccess.content {
        case .empty:
            return .empty(updatedAt: lastSuccess.updatedAt)
        case .populated:
            return .populated(updatedAt: lastSuccess.updatedAt)
        }
    }

    /// Search is useful while real rows remain visible, including during a
    /// refresh or after a failed refresh. It is not mounted for initial loading,
    /// failure, or a true successful-empty result.
    var ownsSearch: Bool {
        switch self {
        case .populated:
            true
        case .refreshing(let success), .stale(let success, _):
            success.content == .populated
        case .loading, .failed, .empty:
            false
        }
    }

    /// Which successful-content composition remains truthful for the surface.
    /// Refreshing and stale states retain the last successful shape; an empty
    /// success must not be routed through a populated list merely because a
    /// later request is in flight or failed.
    var presentation: ResultContent? {
        switch self {
        case .empty:
            .empty
        case .populated:
            .populated
        case .refreshing(let success), .stale(let success, _):
            success.content
        case .loading, .failed:
            nil
        }
    }

    var isSettledEmpty: Bool {
        if case .empty = self { true } else { false }
    }

    /// The visible update status that accompanies retained successful content.
    var retainedUpdate: ResultRetainedUpdate? {
        switch self {
        case .refreshing:
            .refreshing
        case .stale(_, let failure):
            .stale(failure)
        case .loading, .failed, .empty, .populated:
            nil
        }
    }

    /// A page may make a completed-freshness claim only for a settled result.
    /// Refreshing last-good content intentionally returns `nil` until the new
    /// request settles.
    var completedFreshness: ResultFreshness? {
        switch self {
        case .empty(let updatedAt), .populated(let updatedAt):
            .current(updatedAt)
        case .stale(let success, _):
            .stale(success.updatedAt)
        case .loading, .failed, .refreshing:
            nil
        }
    }
}

enum ResultRetainedUpdate: Equatable {
    case refreshing
    case stale(LoadFailure)
}

extension ResultSurfaceState {
    /// Bridges stores that already expose an explicit access/result enum.
    /// Content presence still governs search ownership after a refresh failure,
    /// while permission and plan walls never own a search field.
    static func resource(
        _ state: ResourceAccessState,
        hasContent: Bool,
        updatedAt: Date?,
        isLoading: Bool
    ) -> Self {
        let success = updatedAt.map {
            ResultSuccess(content: hasContent ? .populated : .empty, updatedAt: $0)
        }
        switch state {
        case .failed(let message):
            return resolve(
                lastSuccess: success,
                isLoading: isLoading,
                failure: LoadFailure(summary: message)
            )
        case .empty, .loaded:
            return resolve(lastSuccess: success, isLoading: isLoading, failure: nil)
        case .loading:
            return success.map(Self.refreshing) ?? .loading
        case .denied, .missingScope, .needsPlan, .featureFlagged,
             .unsupportedForPersonalKeys:
            return .failed(LoadFailure(summary: "This result is locked."))
        }
    }
}

/// Freshness of a completed result, including whether a later refresh failed.
enum ResultFreshness: Equatable {
    case current(Date)
    case stale(Date)

    var date: Date {
        switch self {
        case .current(let date), .stale(let date): date
        }
    }

    /// Combines independently loaded sources into one honest page stamp.
    ///
    /// Every relevant source must be settled. The oldest completion governs the
    /// page, because using the newest would overstate the freshness of the other
    /// answers. If any source is stale, the composite is stale as well.
    static func combining(_ states: [ResultSurfaceState]) -> Self? {
        guard !states.isEmpty else { return nil }
        let freshness = states.compactMap(\.completedFreshness)
        guard freshness.count == states.count,
              let oldest = freshness.map(\.date).min()
        else { return nil }
        return freshness.contains(where: \.isStale) ? .stale(oldest) : .current(oldest)
    }

    private var isStale: Bool {
        if case .stale = self { true } else { false }
    }
}
