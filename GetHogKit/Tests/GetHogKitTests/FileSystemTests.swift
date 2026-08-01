import Foundation
import Testing

@testable import GetHogKit

/// `GET /file_system/` — PostHog's unified index of every object in a project.
///
/// The fixture deliberately carries one of every supported object kind so the
/// compound and path-escaping cases remain part of deterministic coverage.
@Suite("Project file system")
struct FileSystemTests {

    // MARK: - Paths

    /// The single most dangerous thing about this endpoint.
    ///
    /// A segment that itself contains a slash escapes it as `\/`, so an entry
    /// named `Observatory / test crew` arrives as
    /// `Sandbox/Archive/Groups/Observatory \/ test crew`.
    /// Splitting on `/` yields four segments and invents an extra folder, a tree that
    /// disagrees with the `depth` the API sent alongside it.
    @Test("does not split a path on a slash that was escaped")
    func escapedSlashInSegment() {
        let path = #"Unfiled/Cohorts/Internal \/ Test users"#
        #expect(FileSystemPath.segments(path) == ["Unfiled", "Cohorts", "Internal / Test users"])

        // What the naive reading would have produced.
        #expect(path.split(separator: "/").count == 4)
    }

    @Test("splits an ordinary path the ordinary way")
    func plainPath() {
        #expect(FileSystemPath.segments("Sandbox/Reports/Weekly orbit samples")
            == ["Sandbox", "Reports", "Weekly orbit samples"])
        #expect(FileSystemPath.segments("Sandbox") == ["Sandbox"])
        #expect(FileSystemPath.segments("") == [""])
    }

    /// Anything the app writes back — a rename, a move — has to re-escape, or it
    /// creates a folder boundary where the user typed a slash in a name.
    @Test("round-trips a segment containing a slash or a backslash")
    func pathRoundTrip() {
        let segments = ["Unfiled", "Cohorts", #"Internal / Test users"#, #"C:\ drive"#]
        let joined = FileSystemPath.joined(segments)
        #expect(FileSystemPath.segments(joined) == segments)
        // The escape really is present in the wire form, not just tolerated.
        #expect(joined.contains(#"Internal \/ Test"#))
    }

    @Test("reads the leaf name off a path with an escaped slash")
    func leafName() {
        #expect(FileSystemPath.name(of: #"Unfiled/Cohorts/Internal \/ Test users"#)
            == "Internal / Test users")
        #expect(FileSystemPath.name(of: "Unfiled") == "Unfiled")
    }

    // MARK: - Entries

    @Test("decodes the project object index")
    func decodesIndex() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))
        #expect(page.count == 27)
        #expect(page.results.count == 9)
        #expect(page.results.allSatisfy { !$0.id.isEmpty })
        #expect(page.results.contains { $0.type == .insight })
        #expect(page.results.contains { $0.type == .folder })
        let refiled = page.results.filter {
            $0.type != .folder && $0.type != .sessionRecordingPlaylist
        }
        #expect(refiled.count == 7)
        #expect(refiled.allSatisfy { $0.depth == 4 })
    }

    @Test("keeps a literal slash inside an entry's own name")
    func entryNameKeepsSlash() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))
        let cohort = try #require(page.results.first { $0.type == .cohort })

        #expect(cohort.name == "Observatory / test crew")
        #expect(cohort.folderSegments == ["Sandbox", "Archive", "Groups"])
        // `depth` is PostHog's own count, and it agrees with a correct split —
        // which is what makes a naive split detectably wrong.
        #expect(cohort.depth == cohort.segments.count)
    }

    /// `type` is an open set: PostHog files new object kinds here as it ships
    /// them. An unrecognised one must survive as itself — dropping the row would
    /// hide an object the user can see in the web console, and throwing would
    /// empty the whole index.
    @Test("quarantines an object type that does not exist yet")
    func unknownType() throws {
        let json = """
        {"id": "x", "path": "Unfiled/Orbital lasers/Beam one", "depth": 3,
         "type": "orbital_laser", "ref": "9", "href": "/lasers/9",
         "shortcut": false, "last_viewed_at": null, "user_access_level": null}
        """
        let entry = try JSONDecoder().decode(FileSystemEntry.self, from: Data(json.utf8))
        guard case .unknown(let raw) = entry.type else {
            Issue.record("expected .unknown, got \(entry.type)")
            return
        }
        #expect(raw == "orbital_laser")
        #expect(entry.type.rawValue == "orbital_laser")
        // The row still has to be presentable and still has to link out.
        #expect(entry.name == "Beam one")
        #expect(entry.href == "/lasers/9")
        #expect(!entry.type.title.isEmpty)
    }

    /// `hog_function/internal_destination` is one type, not a path: the family
    /// and its subtype are joined with a slash. Matching the whole string
    /// against a flat case list drops both hog function rows into `.unknown`
    /// and loses the fact that they are pipeline functions at all.
    @Test("reads the compound hog_function type as a family plus a subtype")
    func compoundHogFunctionType() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))

        let destination = try #require(page.results.first {
            $0.type == .hogFunction(subtype: "internal_destination")
        })
        #expect(destination.type.rawValue == "hog_function/internal_destination")

        let transformation = try #require(page.results.first {
            $0.type == .hogFunction(subtype: "transformation")
        })
        #expect(transformation.type.rawValue == "hog_function/transformation")
        #expect(destination.type != transformation.type)

        // A bare family, should PostHog ever send one, is still a hog function.
        #expect(FileSystemItemType(raw: "hog_function") == .hogFunction(subtype: nil))
    }

    /// `ref` is the object's own id and `href` is a link the console already
    /// built. Together they are what lets this screen hand off to the existing
    /// flag / dashboard / cohort screen instead of reimplementing it.
    @Test("exposes the underlying object id and its ready-made deep link")
    func refAndHref() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))

        let cohort = try #require(page.results.first { $0.type == .cohort })
        #expect(cohort.ref == "730201")
        #expect(cohort.href == "/cohorts/730201")

        let flag = try #require(page.results.first { $0.type == .featureFlag })
        #expect(flag.ref == "710301")
        #expect(flag.href == "/feature_flags/710301")
    }

    @Test("tolerates a folder row that has neither ref nor href")
    func folderWithoutTarget() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))
        let folder = try #require(page.results.first { $0.type == .folder })
        // A folder is a container, not an object — there is nothing to open.
        #expect(folder.ref == nil)
        #expect(folder.href == nil)
        #expect(folder.depth == 1)
        #expect(folder.name == "Sandbox")
        #expect(folder.folderSegments.isEmpty)
    }

    /// `last_viewed_at` is null on most rows and non-null on the handful the
    /// user has actually opened, which is a free "recently viewed" ordering.
    /// Treating null as the epoch would sort every never-opened object as the
    /// least recently viewed thing in the project rather than as unranked.
    @Test("orders by last viewed, keeping the never-viewed rows out of the ranking")
    func recentlyViewedOrdering() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))
        #expect(page.results.contains { $0.lastViewedAt == nil })
        #expect(page.results.filter { $0.lastViewedAt != nil }.count == 2)

        let ordered = page.results.sorted(by: FileSystemEntry.mostRecentlyViewedFirst)
        let viewed = ordered.prefix { $0.lastViewedAt != nil }
        #expect(viewed.count == 2)
        #expect(viewed.first?.type == .insight)
        #expect(viewed.last?.type == .dashboard)
        #expect(ordered.dropFirst(2).allSatisfy { $0.lastViewedAt == nil })
    }

    /// The list envelope carries a top-level `users` array alongside `results` —
    /// a deduplicated directory of the users referenced by the rows' `created_by`.
    /// It is empty on this endpoint in this project because every row's
    /// `created_by` is null, and `Page` ignores it either way. Worth pinning:
    /// if `Page` ever became strict about unknown keys, the index would stop
    /// decoding entirely and the cause would not be obvious.
    @Test("decodes the envelope even though it carries an extra users array")
    func envelopeWithUsers() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))
        #expect(page.results.count == 9)

        // Same envelope with the side-car directory populated, as the sibling
        // endpoints return it once a row has an author.
        let json = """
        {"count": 1, "next": null, "previous": null,
         "results": [{"id": "1", "path": "Unfiled/Insights/Test", "depth": 3,
                      "type": "insight", "ref": "aB1", "href": "/insights/aB1",
                      "shortcut": false, "created_by": 1234,
                      "last_viewed_at": null, "user_access_level": "editor"}],
         "users": [{"id": 1234, "first_name": "Sample", "last_name": "User",
                    "email": "cohort.reader@example.net"}]}
        """
        let withUsers = try Page<FileSystemEntry>.decode(from: Data(json.utf8))
        #expect(withUsers.results.count == 1)
        #expect(withUsers.results.first?.userAccessLevel == "editor")
    }

    /// A row subtitle that joined the folders back with a bare `/` would be
    /// unreadable next to a name that itself contains one: `Unfiled/Cohorts`
    /// above `Internal / Test users` looks like the same separator meaning two
    /// different things.
    @Test("shows the containing folders on one line, spaced away from the names")
    func folderLine() throws {
        let page = try Page<FileSystemEntry>.decode(from: Fixture.data("file_system.json"))

        let cohort = try #require(page.results.first { $0.type == .cohort })
        #expect(cohort.folderDisplayPath == "Sandbox / Archive / Groups")

        let folder = try #require(page.results.first { $0.type == .folder })
        #expect(folder.folderDisplayPath.isEmpty)

        // The compound type reads as its subtype, not as the raw wire value.
        let destination = try #require(page.results.first {
            $0.type == .hogFunction(subtype: "internal_destination")
        })
        #expect(destination.type.title == "Internal destination")
    }

    // MARK: - Endpoint

    @Test("builds the file system listing as plain CRUD")
    func fileSystemEndpoint() {
        let endpoint = PostHogAPI.fileSystem(projectID: 1_001, limit: 300)
        #expect(endpoint.path == "/api/projects/1001/file_system/")
        #expect(endpoint.query.contains { $0.name == "limit" && $0.value == "300" })
        #expect(endpoint.category == .crud)
    }
}
