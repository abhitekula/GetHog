/// The least-privilege scope guidance GetHog shows for a personal API key.
///
/// This is deliberately a catalog of the app's current, user-facing contract,
/// not a claim that every PostHog endpoint has been inventoried. Core read
/// scopes unblock the app's main read surfaces. Write scopes remain optional
/// until a person chooses the corresponding action in the app.
public enum APIKeyScopeGuidance {

    public enum Kind: Sendable, Equatable {
        case coreRead
        case optionalWrite
    }

    /// A live mutation the app actually offers. Every production writer names
    /// one of these cases instead of retaining its own spelling of the scope.
    public enum OptionalWriteAction: String, CaseIterable, Hashable, Sendable {
        case featureFlags
        case alerts
        case annotations
        case errorTracking
        case experiments
        case surveys
    }

    /// Write surfaces differ by shell even though they share the same catalog.
    public enum ClientSurface: Sendable {
        case fullClient
        case appleTV
    }

    public struct Descriptor: Sendable, Equatable, Identifiable {
        public let scope: String
        public let action: String
        public let kind: Kind

        public var id: String { scope }

        init(scope: String, action: String, kind: Kind) {
            self.scope = scope
            self.action = action
            self.kind = kind
        }
    }

    private static let dashboardRead = Descriptor(
        scope: "dashboard:read",
        action: "Read dashboards",
        kind: .coreRead
    )
    private static let insightRead = Descriptor(
        scope: "insight:read",
        action: "Read insights",
        kind: .coreRead
    )
    private static let queryRead = Descriptor(
        scope: "query:read",
        action: "Read events and query-backed surfaces",
        kind: .coreRead
    )
    private static let sessionRecordingRead = Descriptor(
        scope: "session_recording:read",
        action: "Read session recordings and replay",
        kind: .coreRead
    )
    private static let featureFlagRead = Descriptor(
        scope: "feature_flag:read",
        action: "Read feature flags",
        kind: .coreRead
    )
    private static let projectRead = Descriptor(
        scope: "project:read",
        action: "Read the selected project",
        kind: .coreRead
    )
    /// The baseline shown while someone creates a key. It intentionally names
    /// only the read access needed for GetHog's primary surfaces.
    public static let coreReadScopes: [Descriptor] = [
        dashboardRead,
        insightRead,
        queryRead,
        sessionRecordingRead,
        featureFlagRead,
        projectRead,
    ]

    /// The descriptor owned by a named live mutation. This switch is the only
    /// production source of write-scope spellings and their customer-facing
    /// action descriptions.
    public static func optionalWriteDescriptor(for action: OptionalWriteAction) -> Descriptor {
        switch action {
        case .featureFlags:
            Descriptor(
                scope: "feature_flag:write",
                action: "Toggle feature flags and change rollouts",
                kind: .optionalWrite
            )
        case .alerts:
            Descriptor(
                scope: "alert:write",
                action: "Create, change, and snooze alerts",
                kind: .optionalWrite
            )
        case .annotations:
            Descriptor(
                scope: "annotation:write",
                action: "Create annotations",
                kind: .optionalWrite
            )
        case .errorTracking:
            Descriptor(
                scope: "error_tracking:write",
                action: "Triage error issues",
                kind: .optionalWrite
            )
        case .experiments:
            Descriptor(
                scope: "experiment:write",
                action: "End, pause, or resume experiments",
                kind: .optionalWrite
            )
        case .surveys:
            Descriptor(
                scope: "survey:write",
                action: "Launch, stop, or resume surveys",
                kind: .optionalWrite
            )
        }
    }

    /// Granted only when a person intends to perform one of the actions the
    /// current shell can actually execute. Apple TV exposes the live flag
    /// toggle but none of the other five write surfaces.
    public static func optionalWriteActions(for surface: ClientSurface) -> [Descriptor] {
        switch surface {
        case .fullClient:
            OptionalWriteAction.allCases.map(optionalWriteDescriptor(for:))
        case .appleTV:
            [optionalWriteDescriptor(for: .featureFlags)]
        }
    }

    /// The platform projection Settings consumes. Kept in the catalog so a
    /// shared Settings view cannot accidentally advertise another shell's
    /// capabilities.
    public static var currentPlatformOptionalWriteActions: [Descriptor] {
        #if os(tvOS)
        optionalWriteActions(for: .appleTV)
        #else
        optionalWriteActions(for: .fullClient)
        #endif
    }

    /// The catalog entries a locked read surface can recover with when PostHog
    /// does not name a more specific missing scope.
    public static func requiredReadScopes(for capability: Capability) -> [Descriptor] {
        switch capability {
        case .dashboards: [dashboardRead, insightRead]
        case .events: [queryRead]
        case .sessions, .replay: [sessionRecordingRead]
        case .flags: [featureFlagRead]
        }
    }

    /// The one capability that currently offers a write action directly from
    /// its read surface. Other optional writes are owned by their action
    /// controllers and become relevant only when that action is chosen.
    public static func optionalWriteScope(for capability: Capability) -> Descriptor? {
        capability == .flags ? optionalWriteDescriptor(for: .featureFlags) : nil
    }
}
