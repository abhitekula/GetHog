import Foundation

// `GET /file_system/` is PostHog's unified index of every object in a project —
// insights, flags, dashboards, playlists, surveys, cohorts, pipeline functions
// and the folders holding them — in one flat, pageable list. It is the only
// endpoint that answers "what is in this project" without one request per
// resource, which makes it the natural backing for search and for a "recently
// viewed" list.
//
// Read-only here: this app browses the index, it does not reorganise it.

// MARK: - Paths

/// Splitting and joining `file_system` paths.
///
/// Paths look like `Unfiled/Cohorts/Weekly actives`, **but a segment may itself
/// contain a slash, escaped as `\/`**. PostHog creates a cohort called
/// `Internal / Test users` in every project, and it arrives as:
///
///     Unfiled/Cohorts/Internal \/ Test users
///
/// That is three segments. `path.split(separator: "/")` gives four — a cohort
/// named `Internal ` filed under an invented folder called ` Test users`, and a
/// tree that contradicts the `depth` the same row reports. Every read of a path
/// goes through here for that reason.
///
/// A backslash escapes the character after it when that character is `/` or `\`,
/// and is otherwise literal, so a name like `C:\Users` survives unchanged.
public enum FileSystemPath {

    public static func segments(_ path: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escaping = false

        for character in path {
            if escaping {
                // Only `/` and `\` are escapes. A backslash before anything else
                // was a literal backslash in the name, so it is put back.
                if character != "/", character != "\\" { current.append("\\") }
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "/" {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        // A path ending in a lone backslash is malformed; keep it rather than
        // silently deleting a character from someone's name.
        if escaping { current.append("\\") }

        out.append(current)
        return out
    }

    /// The inverse. Anything written back — a rename, a move — must re-escape,
    /// or a slash the user typed in a name becomes a folder boundary.
    public static func joined(_ segments: [String]) -> String {
        segments
            .map {
                $0.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "/", with: "\\/")
            }
            .joined(separator: "/")
    }

    /// The leaf — the object's own name, unescaped.
    public static func name(of path: String) -> String {
        segments(path).last ?? path
    }
}

// MARK: - Types

/// What kind of object a `file_system` row points at.
///
/// An open set: PostHog files new object kinds here as it ships them, and two of
/// the observed values are **compound** — `hog_function/internal_destination`
/// and `hog_function/transformation` are one type each, a family and a subtype
/// joined by a slash, not a path. Anything unrecognised is quarantined in
/// `.unknown` carrying its raw value rather than dropped, because a row this
/// client cannot name is still a row the user can see in the web console.
public enum FileSystemItemType: Sendable, Hashable {
    case insight
    case dashboard
    case featureFlag
    case folder
    case cohort
    case survey
    case sessionRecordingPlaylist
    case hogFunction(subtype: String?)
    case unknown(String)

    public init(raw: String?) {
        switch raw {
        case "insight": self = .insight
        case "dashboard": self = .dashboard
        case "feature_flag": self = .featureFlag
        case "folder": self = .folder
        case "cohort": self = .cohort
        case "survey": self = .survey
        case "session_recording_playlist": self = .sessionRecordingPlaylist
        case "hog_function": self = .hogFunction(subtype: nil)
        case let other?:
            if other.hasPrefix("hog_function/") {
                self = .hogFunction(subtype: String(other.dropFirst("hog_function/".count)))
            } else {
                self = .unknown(other)
            }
        case nil:
            self = .unknown("")
        }
    }

    public var rawValue: String {
        switch self {
        case .insight: "insight"
        case .dashboard: "dashboard"
        case .featureFlag: "feature_flag"
        case .folder: "folder"
        case .cohort: "cohort"
        case .survey: "survey"
        case .sessionRecordingPlaylist: "session_recording_playlist"
        case .hogFunction(let subtype): subtype.map { "hog_function/\($0)" } ?? "hog_function"
        case .unknown(let raw): raw
        }
    }

    public var title: String {
        switch self {
        case .insight: "Insight"
        case .dashboard: "Dashboard"
        case .featureFlag: "Feature flag"
        case .folder: "Folder"
        case .cohort: "Cohort"
        case .survey: "Survey"
        case .sessionRecordingPlaylist: "Replay playlist"
        case .hogFunction(let subtype): subtype.map(Self.humanised) ?? "Pipeline function"
        case .unknown(let raw): raw.isEmpty ? "Unknown" : Self.humanised(raw)
        }
    }

    public var systemImage: String {
        switch self {
        case .insight: "chart.xyaxis.line"
        case .dashboard: "square.grid.2x2"
        case .featureFlag: "flag"
        case .folder: "folder"
        case .cohort: "person.2"
        case .survey: "list.bullet.clipboard"
        case .sessionRecordingPlaylist: "rectangle.stack"
        case .hogFunction: "bolt.horizontal"
        case .unknown: "questionmark.square"
        }
    }

    /// `internal_destination` → `Internal destination`. Same treatment
    /// `HealthIssueDetail` gives an unrecognised kind: readable, and derived
    /// from what PostHog sent rather than invented.
    private static func humanised(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

// MARK: - Entry

/// One object in the project index, from `GET /file_system/`.
///
/// - Note: The list envelope carries a top-level `users` array alongside
///   `results` — a deduplicated directory of the users named by the rows'
///   `created_by`. `Page` currently ignores it because this model does not expose
///   author attribution. If attribution is added, introduce a dedicated envelope
///   instead of silently relying on the sidecar array.
public struct FileSystemEntry: Sendable, Decodable, Identifiable, Hashable {
    public let id: String
    /// The raw path, escapes intact. Read it through `segments`, `name` or
    /// `folderSegments` — never by splitting on `/`.
    public let path: String
    /// PostHog's own segment count. Agrees with `segments.count` on a correct
    /// split, which is what makes a naive one detectably wrong.
    public let depth: Int?
    public let type: FileSystemItemType
    /// The underlying object's own id — `730101` for a cohort, a short id for an
    /// insight, a UUID for a survey. Paired with `type` it is enough to fetch
    /// the object itself.
    public let ref: String?
    /// A deep link the console already built, e.g. `/cohorts/730101`. Preferred
    /// over reconstructing one from `type` and `ref`: PostHog owns its own URL
    /// scheme and has changed it before.
    public let href: String?
    public let isShortcut: Bool
    public let createdAt: Date?
    /// Null on most rows. Non-null only where the user actually opened the
    /// object, which is a free "recently viewed" ordering.
    public let lastViewedAt: Date?
    public let userAccessLevel: String?

    enum CodingKeys: String, CodingKey {
        case id, path, depth, type, ref, href, shortcut
        case createdAt = "created_at"
        case lastViewedAt = "last_viewed_at"
        case userAccessLevel = "user_access_level"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Ids are UUID strings here, but the same pattern elsewhere in this API
        // returns integers, so both are accepted.
        if let string = try? c.decode(String.self, forKey: .id) {
            id = string
        } else if let number = try? c.decode(Int.self, forKey: .id) {
            id = String(number)
        } else {
            id = UUID().uuidString
        }
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        depth = try c.decodeIfPresent(Int.self, forKey: .depth)
        type = FileSystemItemType(raw: try c.decodeIfPresent(String.self, forKey: .type))
        // The contract permits references to resources with either string or
        // numeric identifiers, so both forms are accepted.
        if let string = (try? c.decodeIfPresent(String.self, forKey: .ref)) ?? nil {
            ref = string
        } else if let number = (try? c.decodeIfPresent(Int.self, forKey: .ref)) ?? nil {
            ref = String(number)
        } else {
            ref = nil
        }
        href = try c.decodeIfPresent(String.self, forKey: .href)
        isShortcut = try c.decodeIfPresent(Bool.self, forKey: .shortcut) ?? false
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt).flatMap(PostHogDate.parse)
        lastViewedAt = try c.decodeIfPresent(String.self, forKey: .lastViewedAt)
            .flatMap(PostHogDate.parse)
        userAccessLevel = try c.decodeIfPresent(String.self, forKey: .userAccessLevel)
    }

    /// The path, correctly unescaped.
    public var segments: [String] { FileSystemPath.segments(path) }

    /// The object's own name.
    public var name: String { FileSystemPath.name(of: path) }

    /// Everything above the object — the folders it sits in.
    public var folderSegments: [String] { Array(segments.dropLast()) }

    /// The containing folders as one line, e.g. `Unfiled / Cohorts`. Spaced so a
    /// slash inside a segment name cannot be mistaken for a separator — the
    /// cohort `Internal / Test users` sits under exactly this subtitle.
    public var folderDisplayPath: String { folderSegments.joined(separator: " / ") }

    /// Most recently opened first; never-opened rows keep their existing order
    /// at the end.
    ///
    /// Null `last_viewed_at` is left unranked rather than treated as the epoch:
    /// "never opened" is not the same claim as "opened longest ago", and most of
    /// the index is null.
    public static func mostRecentlyViewedFirst(_ a: FileSystemEntry, _ b: FileSystemEntry) -> Bool {
        switch (a.lastViewedAt, b.lastViewedAt) {
        case let (lhs?, rhs?): lhs > rhs
        case (_?, nil): true
        default: false
        }
    }
}
